#!/usr/bin/env bash
# hevcctl.sh — manage the single-box QSV HEVC library converter (Intel iGPU, in Docker).
# Usage: hevcctl.sh {start|stop|restart|status|logs [N]|stats}   (config via env, see below)
set -uo pipefail
NAME="${NAME:-hevc-convert}"
IMG="${IMG:-lscr.io/linuxserver/ffmpeg:latest}"
WORKDIR="${WORKDIR:-/srv/hevc}"                  # state + logs (+ this converter script)
SCRIPT="${SCRIPT:-$WORKDIR/hevc-convert.sh}"
MEDIA_DIR="${MEDIA_DIR:-/srv/media}"             # media library root (mounted into the container as /media)
PREFS="${PREFS:-}"                               # optional: Plex Preferences.xml, to auto-read the pause token

plex_token(){ sudo grep -oE 'PlexOnlineToken="[^"]+"' "$PREFS" 2>/dev/null | head -1 | sed 's/.*="//;s/"//'; }

start(){
  local TOK; TOK=$(plex_token)
  sudo docker rm -f "$NAME" 2>/dev/null || true
  sudo docker run -d --name "$NAME" --restart unless-stopped \
    --device /dev/dri:/dev/dri --cpus="${CPUS:-4}" --memory="${MEM:-3g}" \
    -v "$MEDIA_DIR":/media -v "$WORKDIR":/work -v "$SCRIPT":/h.sh:ro \
    -e WORK=/work \
    -e QUALITY="${QUALITY:-22}" -e PRESET="${PRESET:-slow}" \
    -e REPLACE_MODE="${REPLACE_MODE:-trash}" -e TRASH_CAP_GB="${TRASH_CAP_GB:-80}" \
    -e SLEEP_BETWEEN="${SLEEP_BETWEEN:-45}" -e MIN_FREE_GB="${MIN_FREE_GB:-200}" \
    -e MIN_AGE_MIN="${MIN_AGE_MIN:-10}" -e RESCAN_SECS="${RESCAN_SECS:-3600}" \
    -e PLEX_PAUSE="${PLEX_PAUSE:-1}" -e PLEX_TOKEN="$TOK" \
    ${LOCK:+-e LOCK="$LOCK"} ${SCAN_DIRS:+-e SCAN_DIRS="$SCAN_DIRS"} ${LIMIT:+-e LIMIT="$LIMIT"} ${ONESHOT:+-e ONESHOT="$ONESHOT"} \
    --entrypoint /bin/bash "$IMG" /h.sh >/dev/null
  echo "started $NAME (ICQ=${QUALITY:-22} preset=${PRESET:-slow} mode=${REPLACE_MODE:-trash})"
}
stop(){ sudo docker stop "$NAME" >/dev/null 2>&1 && echo "stopped $NAME (current file's temp is discarded; original untouched)"; }
status(){
  sudo docker ps -a --filter name="$NAME" --format 'container: {{.Names}}  {{.Status}}'
  echo "--- progress (state.tsv) ---"
  sudo awk -F'\t' '{c[$2]++} END{for(k in c)printf "  %-20s %d\n",k,c[k]}' "$WORKDIR/state.tsv" 2>/dev/null | sort
  echo "--- pool free ---"; df -h "$MEDIA_DIR" 2>/dev/null | tail -1
}
logs(){ sudo docker logs --tail "${1:-40}" "$NAME" 2>&1 | grep -vE "libva info|setlocale" || true; }
stats(){ sudo docker stats --no-stream "$NAME"; }

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  logs)    logs "${2:-40}" ;;
  stats)   stats ;;
  *) echo "usage: $0 {start|stop|restart|status|logs [N]|stats}";;
esac
