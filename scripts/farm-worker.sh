#!/opt/homebrew/bin/bash
# farm-worker.sh — Apple Silicon VideoToolbox HEVC worker for a NAS media library.
#
# Apple Silicon Macs can't always NFS-mount the NAS, so instead of encoding in place
# this pulls each source from the NAS over ssh, encodes locally with VideoToolbox,
# pushes the result back, and triggers an ATOMIC in-place replace ON the NAS (where
# the original lives, in the same dataset). It reads a shared state file to skip files
# any node already handled, and appends its own results there.
#
# Config comes from the environment (see farm.conf.example); deployed per-node by
# farm-deploy.sh as a launchd daemon. Run manually with:
#   NAS=nas.lan REMOTE_ROOT=/srv/media/TV SLICE="Show A
# Show B" /opt/homebrew/bin/bash farm-worker.sh
set -uo pipefail

# ----------------------------- config (env overridable) -----------------------------
NAS="${NAS:?set NAS in farm.conf — the NAS ssh host}"                  # ssh host of the NAS
REMOTE_ROOT="${REMOTE_ROOT:?set REMOTE_ROOT in farm.conf — media library root}"  # library root on the NAS
SLICE="${SLICE:?set SLICE to newline-separated show-dir names under REMOTE_ROOT}"
WORK="${WORK:-$HOME/hevc-farm}"                             # local scratch + state + log
STATE_REMOTE="${STATE_REMOTE:-$REMOTE_ROOT/.hevc-farm-state.tsv}"  # shared progress state on the NAS
VT_QUALITY="${VT_QUALITY:-60}"                              # hevc_videotoolbox -q:v (1-100)
MAX_W="${MAX_W:-1920}"; MAX_H="${MAX_H:-1080}"              # only-downscale ceiling
MIN_SRC_KBPS="${MIN_SRC_KBPS:-3000}"                        # skip sources already leaner
MIN_GAIN_PCT="${MIN_GAIN_PCT:-8}"                           # output must be this % smaller
TRASH_NAME="${TRASH_NAME:-.hevc_trash}"
TRASH_CAP_GB="${TRASH_CAP_GB:-80}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-3}"
RESCAN_SECS="${RESCAN_SECS:-3600}"
ONESHOT="${ONESHOT:-0}"; LIMIT="${LIMIT:-0}"; DRY_RUN="${DRY_RUN:-0}"; RETRY_FAILED="${RETRY_FAILED:-0}"
CONCURRENCY="${CONCURRENCY:-1}"          # parallel encodes per worker (Apple Silicon media engine handles 2-3)
{ [ "$LIMIT" -gt 0 ] || [ "$DRY_RUN" = 1 ]; } && CONCURRENCY=1   # keep tests deterministic / sequential
HOSTTAG="${HOSTTAG:-$(hostname -s)}"
SSH="ssh -o ConnectTimeout=10 -o BatchMode=yes"
# State.tsv keys may use a different path namespace than our ssh/find paths: the probe
# container sees the library at a mount path (MEDIA_CANON) while the NAS host path is
# MEDIA_HOST. canon() maps host->canon so dedup against the shared state lines up.
# Default is identity (no remap) — set both in farm.conf if your container remaps paths.
MEDIA_HOST="${MEDIA_HOST:-/}"; MEDIA_CANON="${MEDIA_CANON:-/}"
canon(){ printf '%s' "${1/#$MEDIA_HOST/$MEDIA_CANON}"; }

mkdir -p "$WORK"
LOG="$WORK/farm.log"; STATE_LOCAL="$WORK/state.tsv"; touch "$STATE_LOCAL"
log(){ printf '%s [%s] %s\n' "$(date '+%F %T')" "$HOSTTAG" "$*" | tee -a "$LOG" >&2; }
hsize(){ awk -v b="${1:-0}" 'BEGIN{u="B";s=b;split("K M G T",a);for(i=1;i<=4&&s>=1024;i++){s/=1024;u=a[i]"B"}printf "%.1f%s",s,u}'; }

# single instance (atomic mkdir + PID lock; macOS has no flock)
LOCKD="$WORK/.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then
  lpid=$(cat "$LOCKD/pid" 2>/dev/null || true)
  if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null; then echo "already running on $HOSTTAG; exiting"; exit 0; fi
  rm -rf "$LOCKD"; mkdir "$LOCKD" 2>/dev/null || { echo "lock race; exiting"; exit 0; }
fi
echo $$ >"$LOCKD/pid"; trap 'rm -rf "$LOCKD"' EXIT INT TERM
rm -f "$WORK"/src.* "$WORK"/out.* 2>/dev/null   # clear stale temps from any prior crashed run

# record one state row both locally and (atomically, append) on the shared NAS state.tsv
state_set(){
  local line; line=$(printf '%s\t%s\t%s\t%s' "$(canon "$1")" "$2" "$(date '+%F %T')" "${3:-}")
  printf '%s\n' "$line" >>"$STATE_LOCAL"
  [ "$DRY_RUN" = 1 ] && return 0   # dry runs preview only — never pollute the shared NAS state
  printf '%s\n' "$line" | $SSH "$NAS" "cat >> ${STATE_REMOTE@Q}" 2>/dev/null || true
}

# pull the shared state -> DONE[path]=status, so we skip what the QSV daemon already did
declare -A DONE
load_state(){
  DONE=(); local cache="$WORK/state.remote"
  $SSH "$NAS" "cat ${STATE_REMOTE@Q}" </dev/null >"$cache" 2>/dev/null || true
  local p s
  if [ -f "$cache" ]; then while IFS=$'\t' read -r p s _; do [ -n "$p" ] && DONE["$p"]="$s"; done < "$cache"; fi
  while IFS=$'\t' read -r p s _; do [ -n "$p" ] && DONE["$p"]="$s"; done < "$STATE_LOCAL"
}

# probe a file ON THE NAS via a persistent ffmpeg container (NO pull) -> sets V_* DUR SIZE EFFKBPS.
# Uses `docker exec` into the long-running hevc-probe container (~0.3s) instead of `docker run`
# (~12s cold start). We hand it the canonical (MEDIA_CANON) path the container sees.
PROBE_CTR="${PROBE_CTR:-hevc-probe}"
remote_probe(){
  local cp; cp=$(canon "$1"); local j
  j=$($SSH "$NAS" "sudo docker exec $PROBE_CTR ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,color_transfer,color_primaries -show_entries format=duration,size -of default=nw=1 ${cp@Q}" </dev/null 2>/dev/null)
  V_CODEC=$(sed -n 's/^codec_name=//p' <<<"$j" | head -1)
  V_W=$(sed -n 's/^width=//p' <<<"$j" | head -1); V_H=$(sed -n 's/^height=//p' <<<"$j" | head -1)
  V_TRC=$(sed -n 's/^color_transfer=//p' <<<"$j" | head -1)
  V_PRIM=$(sed -n 's/^color_primaries=//p' <<<"$j" | head -1)
  DUR=$(sed -n 's/^duration=//p' <<<"$j" | head -1); SIZE=$(sed -n 's/^size=//p' <<<"$j" | head -1)
  : "${V_W:=0}" "${V_H:=0}" "${SIZE:=0}"; EFFKBPS=0
  [ -n "${DUR:-}" ] && awk "BEGIN{exit !(${DUR:-0}>0)}" && EFFKBPS=$(awk "BEGIN{printf \"%d\",($SIZE*8)/$DUR/1000}")
}
classify(){
  case "$V_CODEC" in hevc|h265|av1) echo "skip:already-hevc"; return;; esac
  case "$V_TRC"  in smpte2084|arib-std-b67) echo "skip:hdr"; return;; esac
  case "$V_PRIM" in bt2020|bt2020nc|bt2020c) echo "skip:hdr"; return;; esac
  { [ "$V_W" -ge 1920 ] 2>/dev/null || [ "$V_H" -ge 1080 ] 2>/dev/null; } || { echo "skip:lowres"; return; }
  [ "${EFFKBPS:-0}" -lt "$MIN_SRC_KBPS" ] && { echo "skip:lowbitrate"; return; }
  echo "convert"
}
calc_scale(){
  SCALE_W=""; SCALE_H=""
  awk "BEGIN{exit !($V_W<=$MAX_W && $V_H<=$MAX_H)}" && return
  read -r SCALE_W SCALE_H < <(awk -v w="$V_W" -v h="$V_H" -v mw="$MAX_W" -v mh="$MAX_H" 'BEGIN{
    f=mw/w; g=mh/h; s=(f<g)?f:g; nw=int(w*s); nh=int(h*s); nw-=nw%2; nh-=nh%2;
    if(nw<2)nw=2; if(nh<2)nh=2; printf "%d %d",nw,nh}')
}
# encode LOCAL src -> LOCAL tmp via VideoToolbox -> 0 ok
encode(){
  local src="$1" tmp="$2" fmt="$3"
  local maps=(-map 0:v:0 -map '0:a?') scodec=()
  if [ "$fmt" = matroska ]; then maps+=(-map '0:s?' -map '0:t?'); scodec=(-c:s copy)
  else maps+=(-map '0:s?'); scodec=(-c:s mov_text); fi
  local vf=(); [ -n "$SCALE_W" ] && vf=(-vf "scale=$SCALE_W:$SCALE_H:flags=lanczos")
  local enc=(-c:v hevc_videotoolbox -q:v "$VT_QUALITY" -tag:v hvc1 -c:a copy)
  local out=(-map_metadata 0 -f "$fmt" "$tmp")
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" "${vf[@]}" "${maps[@]}" "${enc[@]}" "${scodec[@]}" "${out[@]}" 2>>"$LOG" && return 0
  log "  retrying without subtitles (incompatible sub codec)"; rm -f "$tmp"
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" "${vf[@]}" -map 0:v:0 -map '0:a?' -sn "${enc[@]}" "${out[@]}" 2>>"$LOG" && return 0
  return 1
}
verify(){
  local tmp="$1" oc od
  [ -s "$tmp" ] || { log "  verify: empty output"; return 1; }
  oc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$tmp" 2>/dev/null)
  [ "$oc" = hevc ] || { log "  verify: out codec=$oc"; return 1; }
  od=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp" 2>/dev/null)
  awk -v a="${DUR:-0}" -v b="${od:-0}" 'BEGIN{d=a-b;if(d<0)d=-d;tol=a*0.01;if(tol<3)tol=3;exit !(b>0&&d<=tol)}' \
    || { log "  verify: duration mismatch src=$DUR out=$od"; return 1; }
  return 0
}

# atomic in-place replace ON the NAS (runs remotely where the original + dataset live)
remote_replace(){  # remote_src remote_tmp outext -> echoes final path
  $SSH "$NAS" "bash -s -- ${1@Q} ${2@Q} ${3@Q} ${TRASH_NAME@Q} ${TRASH_CAP_GB@Q}" <<'RREPLACE'
set -u
src="$1"; tmp="$2"; outext="$3"; tn="$4"; cap="$5"
final="${src%.*}.$outext"
own=$(stat -c '%u:%g' "$src" 2>/dev/null); mode=$(stat -c '%a' "$src" 2>/dev/null)
mp=$(df --output=target "$src" 2>/dev/null | tail -1); td="$mp/$tn"; mkdir -p "$td"
tf="$td/$(basename "$src").$(date +%s)"
mv -f "$src" "$tf" || exit 1
touch "$tf" 2>/dev/null   # stamp insertion time so rolling-trash prune is FIFO, not by original mtime
mv -f "$tmp" "$final" || exit 1
[ -n "$own" ]  && chown "$own"  "$final" 2>/dev/null
[ -n "$mode" ] && chmod "$mode" "$final" 2>/dev/null
capk=$((cap*1024*1024))
while :; do u=$(du -sk "$td" 2>/dev/null | cut -f1); [ "${u:-0}" -le "$capk" ] && break
  old=$(ls -1tr "$td" 2>/dev/null | head -1); [ -z "$old" ] && break; rm -f "$td/$old"; done
printf '%s' "$final"
RREPLACE
}

list_files(){
  local d args=()
  while IFS= read -r d; do [ -n "$d" ] && args+=("$REMOTE_ROOT/$d"); done <<< "$SLICE"
  $SSH "$NAS" "find ${args[*]@Q} -type f \\( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \
       -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.ts' -o -iname '*.mpg' \
       -o -iname '*.mpeg' -o -iname '*.flv' \\) -not -path '*/$TRASH_NAME/*' \
       -not -path '*/node_modules/*' -not -name '*.hevctmp.*' -print0 2>/dev/null | sort -z"
}

process(){  # remote source path
  local rf="$1" base ext lsrc fmt outext lout dir rtmp final
  base=$(basename "$rf"); ext="${base##*.}"; ext="${ext,,}"

  # decide WITHOUT pulling (remote probe via the NAS container)
  remote_probe "$rf"
  if [ -z "$V_CODEC" ]; then log "SKIP(unreadable): $base"; state_set "$rf" failed "probe"; return; fi
  local decision; decision=$(classify)
  if [ "$decision" != convert ]; then
    log "SKIP(${decision#skip:}) $V_CODEC ${V_W}x${V_H} ${EFFKBPS}k: $base"
    state_set "$rf" "skip-${decision#skip:}" "$V_CODEC ${V_W}x${V_H} ${EFFKBPS}k"; return
  fi
  case "$ext" in mkv) fmt=matroska; outext=mkv;; mp4|m4v) fmt=mp4; outext=mp4;; *) fmt=matroska; outext=mkv;; esac
  calc_scale

  log "CONVERT $V_CODEC ${V_W}x${V_H} ${EFFKBPS}k -> HEVC q$VT_QUALITY ${SCALE_W:+(${SCALE_W}x${SCALE_H}) }$(hsize "$SIZE"): $base"
  if [ "$DRY_RUN" = 1 ]; then state_set "$rf" "dry-convert" "${V_W}x${V_H}"; PROCESSED=$((PROCESSED+1)); return; fi

  # only now pull the source (we know it converts)
  lsrc="$WORK/src.$BASHPID.$ext"; lout="$WORK/out.$BASHPID.$outext"
  if ! $SSH "$NAS" "cat ${rf@Q}" </dev/null >"$lsrc"; then log "  PULL FAILED: $base"; rm -f "$lsrc"; state_set "$rf" failed "pull"; return; fi

  local t0 t1; t0=$(date +%s)
  if ! encode "$lsrc" "$lout" "$fmt"; then log "  ENCODE FAILED: $base"; rm -f "$lsrc" "$lout"; state_set "$rf" failed "encode"; return; fi
  if ! verify "$lout"; then log "  VERIFY FAILED: $base"; rm -f "$lsrc" "$lout"; state_set "$rf" failed "verify"; return; fi
  local osz gain; osz=$(stat -f%z "$lout"); gain=$(awk -v o="$osz" -v s="$SIZE" 'BEGIN{printf "%d",(s>0)?(100-(o*100/s)):0}')
  if [ "$gain" -lt "$MIN_GAIN_PCT" ]; then
    log "  NO-GAIN (${gain}%); keeping original: $base"; rm -f "$lsrc" "$lout"; state_set "$rf" "skip-nogain" "gain=${gain}%"; return; fi

  dir=$(dirname "$rf"); rtmp="$dir/.${base}.hevctmp.$outext"
  if ! $SSH "$NAS" "cat > ${rtmp@Q}" <"$lout"; then
    log "  PUSH FAILED: $base"; rm -f "$lsrc" "$lout"; $SSH "$NAS" "rm -f ${rtmp@Q}" </dev/null 2>/dev/null; return; fi
  final=$(remote_replace "$rf" "$rtmp" "$outext")
  t1=$(date +%s)
  if [ -n "$final" ]; then
    log "  DONE ${gain}% smaller ($(hsize "$SIZE") -> $(hsize "$osz")) in $((t1-t0))s -> $(basename "$final")"
    state_set "$rf" done "gain=${gain}% $((t1-t0))s vt$VT_QUALITY $(basename "$final")"; PROCESSED=$((PROCESSED+1))
  else
    log "  REPLACE FAILED: $base"; state_set "$rf" failed "replace"
  fi
  rm -f "$lsrc" "$lout"
}

run_pass(){
  load_state
  local n=0; PROCESSED=0
  log "PASS start (slice: $(echo "$SLICE" | tr '\n' ',' | sed 's/,$//'))  vt=$VT_QUALITY conc=$CONCURRENCY dry=$DRY_RUN"
  # read the whole list into an array first so nothing in the loop (ffmpeg, ssh) eats a live stdin pipe
  local FILES rf active=0; mapfile -d '' FILES < <(list_files)
  for rf in "${FILES[@]}"; do
    [ -z "$rf" ] && continue
    n=$((n+1))
    local st="${DONE[$(canon "$rf")]:-}"
    if [ -n "$st" ]; then
      if [ "$st" = failed ] && [ "$RETRY_FAILED" = 1 ]; then :; else continue; fi
    fi
    if [ "$CONCURRENCY" -le 1 ]; then
      process "$rf"
      [ "$LIMIT" -gt 0 ] && [ "$PROCESSED" -ge "$LIMIT" ] && { log "hit LIMIT=$LIMIT"; break; }
    else
      while [ "$active" -ge "$CONCURRENCY" ]; do wait -n 2>/dev/null; active=$((active-1)); done
      process "$rf" &
      active=$((active+1))
    fi
  done
  [ "$CONCURRENCY" -gt 1 ] && wait
  log "PASS complete: scanned=$n processed=$PROCESSED"
}

while :; do
  run_pass
  { [ "$LIMIT" -gt 0 ] || [ "$DRY_RUN" = 1 ] || [ "$ONESHOT" = 1 ]; } && break
  log "sleeping ${RESCAN_SECS}s before next scan"; sleep "$RESCAN_SECS"
done
