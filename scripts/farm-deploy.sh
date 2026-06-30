#!/opt/homebrew/bin/bash
# farm-deploy.sh — deploy farm-worker.sh + an auto-restarting launchd daemon to each node.
# All deployment specifics live in farm.conf (copy farm.conf.example -> farm.conf and edit).
# Requires bash 4+ on the control box (associative arrays). Run from your control machine:
#   ./farm-deploy.sh            # deploy to all nodes
#   ./farm-deploy.sh <host>     # one node
#   ./farm-deploy.sh status     # daemon + progress on all nodes
#   ./farm-deploy.sh stop       # bootout the daemon on all nodes
#   ./farm-deploy.sh drain      # let in-flight encodes finish, then stop (graceful)
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
  ssh "$H" "rm -f $NODE_DIR/.drain; sudo launchctl bootout system/$LABEL 2>/dev/null; pkill -9 -f farm-worker.sh 2>/dev/null; sleep 3; \
    sudo launchctl bootstrap system $PLIST 2>/dev/null || { sleep 4; sudo launchctl bootstrap system $PLIST; } && echo '  daemon loaded ✓'"
}

case "${1:-all}" in
  status)
    for H in "${HOSTS[@]}"; do
      echo "=== $H ==="
      ssh "$H" "sudo launchctl print system/$LABEL 2>/dev/null | grep -E 'state =|pid =' ; tail -3 $NODE_DIR/farm.log 2>/dev/null"
    done
    # farm-wide (#10): in-flight claims on the NAS + probe container state. best-effort — don't error if unreachable.
    echo "=== farm ==="
    cr="${CLAIMS_REMOTE:-$REMOTE_ROOT/.hevc-claims}"
    echo "  in-flight claims: $(ssh "$NAS" "ls -1 ${cr@Q} 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo '?')"
    echo "  hevc-probe state: $(ssh "$NAS" "sudo docker inspect -f '{{.State.Status}}' ${PROBE_CTR:-hevc-probe} 2>/dev/null" 2>/dev/null || echo '?')" ;;
  stop)
    for H in "${HOSTS[@]}"; do echo "=== stop $H ==="; ssh "$H" "sudo launchctl bootout system/$LABEL 2>/dev/null; pkill -f farm-worker.sh; echo stopped"; done ;;
  drain)  # graceful stop (#4): drop a .drain flag; worker checks it between files & exits cleanly (current encode finishes).
          # NOTE the launchd KeepAlive will relaunch the worker — undrain/deploy removes the flag so it restarts; until then it re-exits.
    drain_timeout="${DRAIN_TIMEOUT:-3600}"   # ponytail: fixed per-node poll cap (default 1h) instead of per-encode ETA math
    for H in "${HOSTS[@]}"; do
      echo "=== drain $H ==="
      ssh "$H" "touch $NODE_DIR/.drain"
      waited=0
      while ssh "$H" "pgrep -f farm-worker.sh >/dev/null 2>&1"; do
        if [ "$waited" -ge "$drain_timeout" ]; then echo "  timeout (still running after ${drain_timeout}s)"; break; fi
        sleep 10; waited=$((waited + 10))
      done
      ssh "$H" "pgrep -f farm-worker.sh >/dev/null 2>&1" || echo "  drained ✓"
    done ;;
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
    # config-drift warning (#12): keys in farm.conf.example but missing from farm.conf. ponytail: ^KEY= / ^KEY=( names only, warn (don't fail).
    if [ -f "$CONF.example" ]; then
      keynames(){ sed -nE 's/^(declare -A )?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$1" | sort -u; }
      while IFS= read -r k; do [ -z "$k" ] && continue
        grep -qE "^(declare -A )?$k=" "$CONF" || echo "⚠ farm.conf missing key '$k' (present in farm.conf.example)"
      done < <(comm -23 <(keynames "$CONF.example") <(keynames "$CONF"))
    fi
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
  all)  for H in "${HOSTS[@]}"; do deploy_one "$H"; done ;;
  *)    deploy_one "$1" ;;
esac
