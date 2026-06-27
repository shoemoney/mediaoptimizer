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
    <key>SLICE</key><string>$slice</string>
    <key>CONCURRENCY</key><string>$conc</string>
    <key>WORK</key><string>$NODE_DIR</string>
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
  all)  for H in "${HOSTS[@]}"; do deploy_one "$H"; done ;;
  *)    deploy_one "$1" ;;
esac
