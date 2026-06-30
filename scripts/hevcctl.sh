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
    -e WORK=/work -e HEVC_LIB=/work/hevc-lib.sh \
    -e QUALITY="${QUALITY:-22}" -e PRESET="${PRESET:-slow}" \
    -e REPLACE_MODE="${REPLACE_MODE:-trash}" -e TRASH_CAP_GB="${TRASH_CAP_GB:-80}" \
    -e SLEEP_BETWEEN="${SLEEP_BETWEEN:-45}" -e MIN_FREE_GB="${MIN_FREE_GB:-200}" \
    -e MIN_AGE_MIN="${MIN_AGE_MIN:-10}" -e RESCAN_SECS="${RESCAN_SECS:-3600}" \
    -e PLEX_PAUSE="${PLEX_PAUSE:-1}" -e PLEX_TOKEN="$TOK" \
    -e RETRY_FAILED="${RETRY_FAILED:-0}" -e CODEC="${CODEC:-hevc}" -e VMAF_MIN="${VMAF_MIN:-0}" -e VT_QUALITY="${VT_QUALITY:-60}" \
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
restore(){  # undo a bad conversion: pull the original back out of the rolling trash (#3)
  local f="${1:-}"; [ -n "$f" ] || { echo "usage: $0 restore <converted-file-path>" >&2; return 2; }
  local dir base stem td hit
  dir=$(dirname "$f"); base=$(basename "$f"); stem="${base%.*}"
  td="$dir/${TRASH_NAME:-.hevc_trash}"
  # convert.sh trashes originals as "<orig-basename>.<unix-ts>"; the stem (name sans ext) links them.
  # ponytail: newest match by mtime via ls -t; assumes no embedded newlines in trash filenames.
  hit=$(ls -t "$td/$stem".* 2>/dev/null | head -1)
  [ -n "$hit" ] || { echo "no trash entry for '$stem' in $td" >&2; return 1; }
  mv -f "$hit" "$f" && echo "restored $(basename "$hit") -> $f"
}
savings(){  # exact lifetime totals from the durable ledger (survives log rotation)
  local sf="$WORKDIR/savings.tsv"
  [ -s "$sf" ] || { echo "no savings recorded yet ($sf)"; return; }
  sudo awk -F'\t' '{b+=$3;a+=$4;n++} END{if(b<=0){print "ledger empty";exit}
    printf "converted %d files: %.2f TB -> %.2f TB  (saved %.2f TB, %.0f%% smaller)\n",
    n,b/2^40,a/2^40,(b-a)/2^40,100*(b-a)/b}' "$sf"
}

case "${1:-status}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  logs)    logs "${2:-40}" ;;
  stats)   stats ;;
  savings) savings ;;
  restore) restore "${2:-}" ;;   # recover an original from the trash (#3)
  failed)  sudo awk -F'\t' '$2=="failed"{c[$4]++} END{for(k in c)printf "  %-22s %d\n",k,c[k]}' "$WORKDIR/state.tsv" 2>/dev/null | sort || echo "no failures (or no state.tsv yet)" ;;
  retry)   stop; RETRY_FAILED=1 start ;;   # re-attempt previously-failed files (#8)
  *) echo "usage: $0 {start|stop|restart|status|logs [N]|stats|savings|restore <path>|failed|retry}";;
esac
