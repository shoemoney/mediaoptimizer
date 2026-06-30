#!/opt/homebrew/bin/bash
# farm-deploy.sh — deploy farm-worker.sh + an auto-restarting launchd daemon to each node.
# All deployment specifics live in farm.conf (copy farm.conf.example -> farm.conf and edit).
# Requires bash 4+ on the control box (associative arrays). Run from your control machine:
#   ./farm-deploy.sh            # deploy to all nodes
#   ./farm-deploy.sh <host>     # one node
#   ./farm-deploy.sh status     # daemon + progress on all nodes
#   ./farm-deploy.sh stop       # bootout the daemon on all nodes
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKER="$HERE/farm-worker.sh"
LIB="$HERE/hevc-lib.sh"
[ -f "$LIB" ] || { echo "missing $LIB (shared logic sourced by farm-worker.sh)"; exit 1; }
CONF="${CONF:-$HERE/farm.conf}"
[ -f "$CONF" ] || { echo "missing config: $CONF  (copy farm.conf.example -> farm.conf and edit)"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${LABEL:?set LABEL in farm.conf}" "${NODE_USER:?set NODE_USER}" "${NODE_DIR:?set NODE_DIR}" \
  "${NODE_BASH:?set NODE_BASH}" "${NAS:?set NAS}" "${REMOTE_ROOT:?set REMOTE_ROOT}"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

deploy_one(){
  local H="$1" slice="${SLICE[$1]}" conc="${CONC[$1]:-3}"
  echo "=== deploy $H (concurrency=$conc) ==="
  ssh "$H" "mkdir -p ${NODE_DIR@Q}"
  scp -q "$WORKER" "$H:$NODE_DIR/farm-worker.sh"
  scp -q "$LIB" "$H:$NODE_DIR/hevc-lib.sh"
  # install the launchd daemon (runs as $NODE_USER so it has that user's ssh keys; KeepAlive auto-restarts)
  ssh "$H" "sudo tee $PLIST >/dev/null" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$NODE_BASH</string><string>$NODE_DIR/farm-worker.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>NAS</key><string>$NAS</string>
    <key>REMOTE_ROOT</key><string>$REMOTE_ROOT</string>
    <key>STATE_REMOTE</key><string>${STATE_REMOTE:-$REMOTE_ROOT/.hevc-farm-state.tsv}</string>
    <key>MEDIA_HOST</key><string>${MEDIA_HOST:-/}</string>
    <key>MEDIA_CANON</key><string>${MEDIA_CANON:-/}</string>
    <key>PROBE_CTR</key><string>${PROBE_CTR:-hevc-probe}</string>
    <key>VT_QUALITY</key><string>${VT_QUALITY:-60}</string>
    <key>VT_CODEC</key><string>${VT_CODEC:-hevc}</string>
    <key>TARGET_CODEC</key><string>${TARGET_CODEC:-${VT_CODEC:-hevc}}</string>
    <key>VMAF_MIN</key><string>${VMAF_MIN:-0}</string>
    <key>SLICE</key><string>$slice</string>
    <key>CONCURRENCY</key><string>$conc</string>
    <key>WORK</key><string>$NODE_DIR</string>
    <key>HEVC_LIB</key><string>$NODE_DIR/hevc-lib.sh</string>
    <key>CLAIMS_REMOTE</key><string>${CLAIMS_REMOTE:-$REMOTE_ROOT/.hevc-claims}</string>
    <key>SAVINGS_REMOTE</key><string>${SAVINGS_REMOTE:-$REMOTE_ROOT/.hevc-savings.tsv}</string>
    <key>PATH</key><string>$(dirname "$NODE_BASH"):/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>UserName</key><string>$NODE_USER</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$NODE_DIR/launchd.out</string>
  <key>StandardErrorPath</key><string>$NODE_DIR/launchd.err</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
  # bootout + kill leftover ffmpeg children, then bootstrap (retry once — launchd EIO race if not fully torn down)
  ssh "$H" "sudo launchctl bootout system/$LABEL 2>/dev/null; pkill -9 -f farm-worker.sh 2>/dev/null; sleep 3; \
    sudo launchctl bootstrap system $PLIST 2>/dev/null || { sleep 4; sudo launchctl bootstrap system $PLIST; } && echo '  daemon loaded ✓'"
}

case "${1:-all}" in
  status)
    for H in "${HOSTS[@]}"; do
      echo "=== $H ==="
      ssh "$H" "sudo launchctl print system/$LABEL 2>/dev/null | grep -E 'state =|pid =' ; tail -3 $NODE_DIR/farm.log 2>/dev/null"
    done ;;
  stop)
    for H in "${HOSTS[@]}"; do echo "=== stop $H ==="; ssh "$H" "sudo launchctl bootout system/$LABEL 2>/dev/null; pkill -f farm-worker.sh; echo stopped"; done ;;
  check)  # lint farm.conf before you deploy (#5): NAS path, host reachability, disjoint slices, numeric CONC
    rc=0
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$NAS" "test -d ${REMOTE_ROOT@Q}" 2>/dev/null \
      && echo "NAS $NAS REMOTE_ROOT ok" || { echo "✗ NAS $NAS: REMOTE_ROOT $REMOTE_ROOT missing/unreachable"; rc=1; }
    declare -A seen=()
    for H in "${HOSTS[@]}"; do
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$H" true 2>/dev/null && echo "$H reachable" \
        || { echo "✗ $H unreachable (ssh BatchMode)"; rc=1; }
      case "${CONC[$H]:-3}" in ''|*[!0-9]*) echo "✗ $H CONC='${CONC[$H]:-}' not numeric"; rc=1;; esac
      while IFS= read -r d; do [ -z "$d" ] && continue
        if [ -n "${seen[$d]:-}" ]; then echo "✗ slice '$d' assigned to BOTH ${seen[$d]} and $H"; rc=1
        else seen[$d]="$H"; fi
      done <<<"${SLICE[$H]:-}"
    done
    [ $rc = 0 ] && echo "✅ farm.conf checks pass" || echo "❌ fix the above before deploy"
    exit $rc ;;
  kick)   # force-restart the daemon on every node (interrupts in-progress encodes).
          # For unattended stall-healing + alerting, cron scripts/farm-watchdog.sh instead (#7).
    for H in "${HOSTS[@]}"; do echo "kick $H"; ssh "$H" "sudo launchctl kickstart -k system/$LABEL"; done ;;
  failed) # tally failed entries in the shared state by reason (#8)
    ssh "$NAS" "awk -F'\t' '\$2==\"failed\"{c[\$4]++} END{for(k in c)printf \"  %-22s %d\n\",k,c[k]}' ${STATE_REMOTE:-$REMOTE_ROOT/.hevc-farm-state.tsv} 2>/dev/null" \
      | sort || echo "no failures (or no shared state yet)" ;;
  retry)  # drop failed rows from shared state so the next scan re-attempts them (#8)
    sr="${STATE_REMOTE:-$REMOTE_ROOT/.hevc-farm-state.tsv}"
    n=$(ssh "$NAS" "grep -c \$'\tfailed\t' ${sr@Q} 2>/dev/null" || echo 0)
    ssh "$NAS" "sed -i.bak \$'/\tfailed\t/d' ${sr@Q}" && echo "cleared ${n:-0} failed row(s) from $sr — they retry next scan (backup: $sr.bak)" ;;
  reverify)  # sample-decode already-converted files to catch silent corruption (originals are gone -> alert only)
    REVERIFY_SAMPLE="${REVERIFY_SAMPLE:-20}"
    REVERIFY_SECS="${REVERIFY_SECS:-20}"
    PROBE_CTR="${PROBE_CTR:-hevc-probe}"
    sr="${STATE_REMOTE:-$REMOTE_ROOT/.hevc-farm-state.tsv}"
    # pull done-paths from shared state; state col1 is already the canon (container-visible) path
    mapfile -t DONE_PATHS < <(ssh "$NAS" "cat ${sr@Q} 2>/dev/null" \
      | awk -F'\t' '$2=="done"{print $1}')
    total="${#DONE_PATHS[@]}"
    if [ "$total" -eq 0 ]; then echo "reverify: no done entries in $sr"; exit 0; fi
    # random sample: prefer sort -R (GNU coreutils); fall back to awk rand (macOS)
    if sort --version 2>/dev/null | grep -q GNU; then
      mapfile -t SAMPLE < <(printf '%s\n' "${DONE_PATHS[@]}" | sort -R | head -"$REVERIFY_SAMPLE")
    else
      mapfile -t SAMPLE < <(printf '%s\n' "${DONE_PATHS[@]}" \
        | awk -v n="$REVERIFY_SAMPLE" -v seed="$RANDOM" \
          'BEGIN{srand(seed)} {lines[NR]=$0} END{
            for(i=NR;i>=1;i--){j=int(rand()*i)+1; t=lines[i]; lines[i]=lines[j]; lines[j]=t}
            for(k=1;k<=n&&k<=NR;k++) print lines[k]}')
    fi
    sampled="${#SAMPLE[@]}"
    echo "reverify: sampling $sampled of $total done files (REVERIFY_SECS=$REVERIFY_SECS)"
    ok=0; fail=0; declare -a FAILED=()
    for p in "${SAMPLE[@]}"; do
      [ -z "$p" ] && continue
      if ssh "$NAS" "sudo docker exec ${PROBE_CTR} ffmpeg -v error -xerror -nostdin -t ${REVERIFY_SECS} -i ${p@Q} -f null -" 2>/dev/null; then
        echo "  OK   $p"; ok=$((ok+1))
      else
        echo "  FAIL $p"; fail=$((fail+1)); FAILED+=("$p")
      fi
    done
    echo "reverify: $sampled sampled, $ok ok, $fail FAILED"
    if [ "${#FAILED[@]}" -gt 0 ]; then
      echo "--- files needing re-download ---"
      printf '  %s\n' "${FAILED[@]}"
      exit 1
    fi ;;
  all)  for H in "${HOSTS[@]}"; do deploy_one "$H"; done ;;
  *)    deploy_one "$1" ;;
esac
