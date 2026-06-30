#!/usr/bin/env bash
# hevc-convert.sh — gentle, resumable QSV HEVC 1080p library converter
# Runs inside lscr.io/linuxserver/ffmpeg (has ffmpeg/ffprobe w/ Intel QSV).
# Designed to be VERY easy on CPU/IO: hardware (iGPU) encode, one file at a
# time, niced/ionice'd, sleeps between files, pauses while Plex is transcoding,
# and a free-space guard so it never fills the pool.
#
# Safety: encode -> verify (codec+duration+size) -> only then replace original.
# Originals go to a rolling, size-capped trash inside the same ZFS dataset so a
# replace is an instant atomic rename (never a slow cross-dataset copy).
set -uo pipefail

# ----------------------------- Config (env overridable) -----------------------------
# SCAN_DIRS: one directory per line (newline-delimited) so paths may contain spaces.
SCAN_DIRS="${SCAN_DIRS:-/media/videos/Movies
/media/videos/TV}"
WORK="${WORK:-/work}"                  # writable: state + logs
QUALITY="${QUALITY:-22}"               # QSV ICQ (global_quality); lower=better/bigger
PRESET="${PRESET:-slow}"               # QSV preset
MAX_W="${MAX_W:-1920}"; MAX_H="${MAX_H:-1080}"
MIN_SRC_KBPS="${MIN_SRC_KBPS:-3000}"   # skip sources already leaner than this
MIN_GAIN_PCT="${MIN_GAIN_PCT:-8}"      # output must be >= this % smaller, else keep original
SLEEP_BETWEEN="${SLEEP_BETWEEN:-45}"   # idle seconds between files (gentle on IO)
MIN_AGE_MIN="${MIN_AGE_MIN:-10}"       # skip files modified within N min (still importing)
MIN_FREE_GB="${MIN_FREE_GB:-200}"      # pause if pool free space drops below this
REPLACE_MODE="${REPLACE_MODE:-trash}"  # trash | keep
TRASH_CAP_GB="${TRASH_CAP_GB:-80}"     # rolling trash cap per dataset
TRASH_NAME="${TRASH_NAME:-.hevc_trash}"
RESCAN_SECS="${RESCAN_SECS:-3600}"     # wait between full library passes
ONESHOT="${ONESHOT:-0}"                 # run exactly one pass then exit (good for cron)
DRY_RUN="${DRY_RUN:-0}"
LIMIT="${LIMIT:-0}"                    # max files this run (0 = unlimited; set 1 to stop after one)
RETRY_FAILED="${RETRY_FAILED:-0}"
PLEX_PAUSE="${PLEX_PAUSE:-1}"
MAX_PLEX_WAIT_MIN="${MAX_PLEX_WAIT_MIN:-120}" # after this long continuously waiting, proceed anyway (0=forever)
PLEX_URL="${PLEX_URL:-http://localhost:32400}"
PLEX_TOKEN="${PLEX_TOKEN:-}"
ENCODER="${ENCODER:-qsv}"              # qsv (Intel iGPU) | videotoolbox (Apple Silicon)
VT_QUALITY="${VT_QUALITY:-60}"         # hevc_videotoolbox constant quality -q:v (1-100, higher=better)
CODEC="${CODEC:-hevc}"                 # hevc | av1  (#12; av1_qsv on Intel, av1_videotoolbox on M3+)
TARGET_CODEC="${TARGET_CODEC:-$CODEC}" # verify() expects this output codec_name
VMAF_MIN="${VMAF_MIN:-0}"              # >0 enables the perceptual quality gate (#1; slow, whole-file)

STATE="${STATE:-$WORK/state.tsv}"; LOG="${LOG:-$WORK/convert.log}"; LOCK="${LOCK:-$WORK/.lock}"
SAVINGS="${SAVINGS:-$WORK/savings.tsv}"   # durable, never-rotated before/after byte ledger
mkdir -p "$WORK"; touch "$STATE"

# ---- platform shims (GNU/Linux for the QSV box vs BSD/macOS for Apple Silicon) ----
case "$(uname -s)" in
  Darwin)
    stat_owner(){ stat -f '%u:%g' "$1" 2>/dev/null; }
    stat_mode(){ stat -f '%Lp' "$1" 2>/dev/null; }
    stat_size(){ stat -f '%z' "$1" 2>/dev/null; }
    free_gb(){ df -g "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
    mount_target(){ df "$1" 2>/dev/null | awk 'NR==2{for(i=9;i<=NF;i++)printf (i>9?" ":"") $i}'; }
    ;;
  *)
    stat_owner(){ stat -c '%u:%g' "$1" 2>/dev/null; }
    stat_mode(){ stat -c '%a' "$1" 2>/dev/null; }
    stat_size(){ stat -c '%s' "$1" 2>/dev/null; }
    free_gb(){ df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }
    mount_target(){ df --output=target "$1" 2>/dev/null | tail -1; }
    ;;
esac

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }
# shared logic — classify/calc_scale/verify/hsize/compact_state/record_savings.
# In the container hevcctl sets HEVC_LIB=/work/hevc-lib.sh (the lib lives in WORKDIR).
source "${HEVC_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hevc-lib.sh}"

# #12: fall back to hevc if the requested av1 encoder isn't usable on this box (old Intel iGPU
# lacks av1_qsv; pre-M3 Apple lacks av1_videotoolbox). Probed once at startup.
if [ "$CODEC" = av1 ]; then
  _avenc="av1_qsv"; [ "$ENCODER" = videotoolbox ] && _avenc="av1_videotoolbox"
  codec_supported "$_avenc" || { log "$_avenc unusable here → falling back to hevc"; CODEC=hevc; TARGET_CODEC=hevc; }
fi

# single instance (flock on Linux; atomic mkdir+PID lock on macOS, which has no flock)
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "another instance is running; exiting"; exit 0; }
else
  LOCKD="$LOCK.d"
  if ! mkdir "$LOCKD" 2>/dev/null; then
    lpid=$(cat "$LOCKD/pid" 2>/dev/null || true)
    if [ -n "${lpid:-}" ] && kill -0 "$lpid" 2>/dev/null; then echo "another instance is running; exiting"; exit 0; fi
    rm -rf "$LOCKD"; mkdir "$LOCKD" 2>/dev/null || { echo "lock race; exiting"; exit 0; }
  fi
  echo $$ > "$LOCKD/pid"; trap 'rm -rf "$LOCKD"' EXIT INT TERM
fi

NICE=(); command -v nice  >/dev/null && NICE=(nice -n 19)
command -v ionice >/dev/null && NICE+=(ionice -c 3)

# run ffmpeg with our standard niceness + quiet flags, appending stderr to the log
ff(){ "${NICE[@]}" ffmpeg -hide_banner -loglevel error -y "$@" 2>>"$LOG"; }

state_set(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date '+%F %T')" "${3:-}" >>"$STATE"; }

plex_busy(){
  [ "$PLEX_PAUSE" = 1 ] && [ -n "$PLEX_TOKEN" ] || return 1
  local x; x=$(curl -sf -m 5 "$PLEX_URL/status/sessions?X-Plex-Token=$PLEX_TOKEN" 2>/dev/null) || return 1
  echo "$x" | grep -q 'videoDecision="transcode"'
}

# Probe -> sets V_CODEC V_W V_H V_TRC V_PRIM DUR SIZE EFFKBPS
probe(){
  local f="$1" j
  j=$(ffprobe -v error -select_streams v:0 \
       -show_entries stream=codec_name,width,height,color_transfer,color_primaries \
       -show_entries format=duration,size -of default=nw=1 "$f" 2>/dev/null)
  V_CODEC=$(sed -n 's/^codec_name=//p' <<<"$j" | head -1)
  V_W=$(sed -n 's/^width=//p' <<<"$j" | head -1)
  V_H=$(sed -n 's/^height=//p' <<<"$j" | head -1)
  V_TRC=$(sed -n 's/^color_transfer=//p' <<<"$j" | head -1)
  V_PRIM=$(sed -n 's/^color_primaries=//p' <<<"$j" | head -1)
  DUR=$(sed -n 's/^duration=//p' <<<"$j" | head -1)
  SIZE=$(sed -n 's/^size=//p' <<<"$j" | head -1)
  : "${V_W:=0}" "${V_H:=0}" "${SIZE:=0}"
  EFFKBPS=0
  if [ -n "${DUR:-}" ] && awk "BEGIN{exit !(${DUR:-0}>0)}"; then
    EFFKBPS=$(awk "BEGIN{printf \"%d\", ($SIZE*8)/$DUR/1000}")
  fi
}

# classify() and calc_scale() now live in hevc-lib.sh (sourced above)

# encode src tmp fmt  (uses SCALE_W/SCALE_H) -> 0 ok
encode(){
  local src="$1" tmp="$2" fmt="$3"
  local maps=(-map 0:v:0 -map '0:a?') scodec=()
  if [ "$fmt" = matroska ]; then maps+=(-map '0:s?' -map '0:t?'); scodec=(-c:s copy)
  else maps+=(-map '0:s?'); scodec=(-c:s mov_text); fi
  local out=(-map_metadata 0 -f "$fmt" "$tmp")

  # ===== Apple Silicon VideoToolbox path (Mac nodes) =====
  if [ "$ENCODER" = videotoolbox ]; then
    local vtag=(); [ "$CODEC" = hevc ] && vtag=(-tag:v hvc1)   # hvc1 tag is HEVC-only
    local vtenc=(-c:v "${CODEC}_videotoolbox" -q:v "$VT_QUALITY" "${vtag[@]}" -c:a copy)
    local vf=(); [ -n "$SCALE_W" ] && vf=(-vf "scale=$SCALE_W:$SCALE_H:flags=lanczos")
    # #5: skip the doomed first attempt when source subs can't go in this container (ffprobe pre-check)
    if subs_incompatible "$fmt" "$src"; then
      log "  dropping incompatible subs up front (ffprobe pre-check)"
      ff -i "$src" "${vf[@]}" -map 0:v:0 -map '0:a?' -sn "${vtenc[@]}" "${out[@]}" && return 0
      return 1
    fi
    ff -i "$src" "${vf[@]}" "${maps[@]}" "${vtenc[@]}" "${scodec[@]}" "${out[@]}" && return 0
    log "  retrying without subtitles (incompatible sub codec)"
    rm -f "$tmp"
    ff -i "$src" "${vf[@]}" -map 0:v:0 -map '0:a?' -sn "${vtenc[@]}" "${out[@]}" && return 0
    return 1
  fi

  # ===== Intel QSV path =====
  local enc=(-c:v "${CODEC}_qsv" -global_quality "$QUALITY" -preset "$PRESET" -c:a copy)

  # ---- Path 1: full hardware (QSV decode + scale + encode) ----
  local hw=(-hwaccel qsv -hwaccel_output_format qsv -i "$src")
  [ -n "$SCALE_W" ] && hw+=(-vf "vpp_qsv=w=$SCALE_W:h=$SCALE_H:scale_mode=hq")
  # #5: skip subs up front when they can't go in this container — drop straight to -sn, no doomed pass
  if subs_incompatible "$fmt" "$src"; then
    log "  dropping incompatible subs up front (ffprobe pre-check)"
    ff "${hw[@]}" -map 0:v:0 -map '0:a?' -sn "${enc[@]}" "${out[@]}" && return 0
  else
    ff "${hw[@]}" "${maps[@]}" "${enc[@]}" "${scodec[@]}" "${out[@]}" && return 0
  fi

  # ---- Path 2: software decode + QSV encode ----
  log "  HW path failed; software-decode + QSV-encode fallback"
  rm -f "$tmp"
  local sw_vf="format=nv12,hwupload=extra_hw_frames=64"
  [ -n "$SCALE_W" ] && sw_vf="scale=$SCALE_W:$SCALE_H:flags=lanczos,$sw_vf"
  local sw=(-init_hw_device qsv=hw -filter_hw_device hw -i "$src" -vf "$sw_vf")
  ff "${sw[@]}" "${maps[@]}" "${enc[@]}" "${scodec[@]}" "${out[@]}" && return 0

  # ---- Path 3: drop subs (e.g. image subs can't convert to mp4 mov_text) ----
  log "  retrying without subtitles (incompatible sub codec)"
  rm -f "$tmp"
  ff "${sw[@]}" -map 0:v:0 -map '0:a?' -sn "${enc[@]}" "${out[@]}" && return 0
  return 1
}

# verify() now lives in hevc-lib.sh (sourced above) — incl. the decode-sample check

prune_trash(){
  local td="$1" cap=$((TRASH_CAP_GB*1024*1024)) used oldest
  while :; do
    used=$(du -sk "$td" 2>/dev/null | cut -f1); [ "${used:-0}" -le "$cap" ] && break
    oldest=$(ls -1tr "$td" 2>/dev/null | head -1); [ -z "$oldest" ] && break
    rm -f "$td/$oldest"
  done
}

# replace src with verified tmp; preserve owner+mode; echo final path
replace_file(){
  local src="$1" tmp="$2" outext="$3" final own mode mp td
  own=$(stat_owner "$src"); mode=$(stat_mode "$src")
  final="${src%.*}.$outext"
  case "$REPLACE_MODE" in
    keep)  final="${src%.*}.hevc.$outext"; mv -f "$tmp" "$final" ;;
    trash|*)
      mp=$(mount_target "$src"); td="$mp/$TRASH_NAME"; mkdir -p "$td"
      mv -f "$src" "$td/$(basename "$src").$(date +%s)"
      mv -f "$tmp" "$final"; prune_trash "$td" ;;
  esac
  [ -n "$own" ]  && chown "$own"  "$final" 2>/dev/null
  [ -n "$mode" ] && chmod "$mode" "$final" 2>/dev/null
  printf '%s' "$final"
}

declare -A DONE
load_state(){ compact_state "$STATE"; DONE=(); local p s; while IFS=$'\t' read -r p s _; do [ -n "$p" ] && DONE["$p"]="$s"; done < "$STATE"; }

run_pass(){
  load_state
  local SCAN_ARR=(); local d
  while IFS= read -r d; do [ -n "$d" ] && SCAN_ARR+=("$d"); done <<< "$SCAN_DIRS"
  for d in "${SCAN_ARR[@]}"; do find "$d" -type f -name '.*.hevctmp.*' -delete 2>/dev/null; done
  mapfile -d '' FILES < <(find "${SCAN_ARR[@]}" -type f \
      \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi' \
         -o -iname '*.mov' -o -iname '*.wmv' -o -iname '*.ts' -o -iname '*.mpg' \
         -o -iname '*.mpeg' -o -iname '*.flv' \) \
      -not -path "*/$TRASH_NAME/*" -not -path '*/node_modules/*' -print0 2>/dev/null | sort -z)
  log "PASS start: ${#FILES[@]} candidate files; ICQ=$QUALITY preset=$PRESET mode=$REPLACE_MODE dry=$DRY_RUN"
  local f st processed=0
  for f in "${FILES[@]}"; do
    case "$f" in *"/$TRASH_NAME/"*|*.hevctmp.*) continue;; esac
    st="${DONE[$f]:-}"
    if [ -n "$st" ]; then
      if [ "$st" = failed ] && [ "$RETRY_FAILED" = 1 ]; then :; else continue; fi
    fi
    # skip very recently modified (still importing)
    if find "$f" -mmin "-$MIN_AGE_MIN" 2>/dev/null | grep -q .; then
      log "SKIP(fresh) recently modified: $(basename "$f")"; continue; fi

    probe "$f"
    if [ -z "$V_CODEC" ]; then log "SKIP(unreadable): $(basename "$f")"; state_set "$f" failed "probe"; continue; fi
    local decision; decision=$(classify)
    if [ "$decision" != convert ]; then
      local r="${decision#skip:}"
      log "SKIP($r) $V_CODEC ${V_W}x${V_H} ${EFFKBPS}k: $(basename "$f")"
      state_set "$f" "skip-$r" "$V_CODEC ${V_W}x${V_H} ${EFFKBPS}k"; continue
    fi

    local fg; fg=$(free_gb "$(dirname "$f")")
    if [ "${fg:-9999}" -lt "$MIN_FREE_GB" ]; then
      log "PAUSE: free ${fg}GB < ${MIN_FREE_GB}GB; sleeping 300s"; sleep 300; continue; fi
    if [ "$PLEX_PAUSE" = 1 ]; then
      local waited=0
      while plex_busy; do
        if [ "$MAX_PLEX_WAIT_MIN" -gt 0 ] && [ "$waited" -ge "$((MAX_PLEX_WAIT_MIN*60))" ]; then
          log "Plex still transcoding after ${MAX_PLEX_WAIT_MIN}m; proceeding (QSV handles concurrent)"; break; fi
        log "Plex is transcoding; waiting 60s"; sleep 60; waited=$((waited+60))
      done; fi

    local extl fmt outext; extl="${f##*.}"; extl="${extl,,}"
    case "$extl" in mkv) fmt=matroska; outext=mkv;; mp4|m4v) fmt=mp4; outext=mp4;; *) fmt=matroska; outext=mkv;; esac
    calc_scale
    pick_quality   # per-resolution tier (#4); no-op at the default MAX_H=1080
    local dir base tmp; dir=$(dirname "$f"); base=$(basename "$f"); tmp="$dir/.${base}.hevctmp.$outext"
    local qtag; [ "$ENCODER" = videotoolbox ] && qtag="q$VT_QUALITY" || qtag="ICQ$QUALITY"

    log "CONVERT $V_CODEC ${V_W}x${V_H} ${EFFKBPS}k -> ${CODEC^^} $qtag ${SCALE_W:+(${SCALE_W}x${SCALE_H}) }$(hsize "$SIZE"): $base"
    if [ "$DRY_RUN" = 1 ]; then state_set "$f" "dry-convert" "${V_W}x${V_H}->${SCALE_W:-keep}"; processed=$((processed+1));
      [ "$LIMIT" -gt 0 ] && [ "$processed" -ge "$LIMIT" ] && break; continue; fi

    local t0 t1; t0=$(date +%s)
    if ! encode "$f" "$tmp" "$fmt"; then log "  ENCODE FAILED: $base"; rm -f "$tmp"; state_set "$f" failed "encode"; continue; fi
    if ! verify "$tmp"; then log "  VERIFY FAILED: $base"; rm -f "$tmp"; state_set "$f" failed "verify"; continue; fi
    if ! vmaf_ok "$tmp" "$f"; then log "  VMAF FAILED: $base"; rm -f "$tmp"; state_set "$f" failed "vmaf"; continue; fi
    local osz gain; osz=$(stat_size "$tmp"); gain=$(awk -v o="$osz" -v s="$SIZE" 'BEGIN{printf "%d",(s>0)?(100-(o*100/s)):0}')
    if [ "$gain" -lt "$MIN_GAIN_PCT" ]; then
      log "  NO-GAIN (${gain}% < ${MIN_GAIN_PCT}%); keeping original: $base"
      rm -f "$tmp"; state_set "$f" "skip-nogain" "gain=${gain}%"; continue; fi
    local final; final=$(replace_file "$f" "$tmp" "$outext"); t1=$(date +%s)
    log "  DONE ${gain}% smaller ($(hsize "$SIZE") -> $(hsize "$osz")) in $((t1-t0))s -> $(basename "$final")"
    state_set "$f" done "gain=${gain}% $((t1-t0))s $(basename "$final")"
    record_savings "$SIZE" "$osz" "$(basename "$final")"
    processed=$((processed+1))
    [ "$LIMIT" -gt 0 ] && [ "$processed" -ge "$LIMIT" ] && { log "hit LIMIT=$LIMIT"; break; }
    sleep "$SLEEP_BETWEEN"
  done
  log "PASS complete: processed=$processed"
}

while :; do
  run_pass
  { [ "$LIMIT" -gt 0 ] || [ "$DRY_RUN" = 1 ] || [ "$ONESHOT" = 1 ]; } && break
  log "sleeping ${RESCAN_SECS}s before next library scan"
  sleep "$RESCAN_SECS"
done
