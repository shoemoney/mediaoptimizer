#!/usr/bin/env bash
# hevc-estimate.sh — dry-run savings estimator for the HEVC farm.
# Point it at a media library root; it probes each video, classifies it,
# and projects how much disk a full HEVC pass would reclaim — before you commit.
#
# Ceiling note: EST_RATIO is a fleet heuristic (~58% smaller in practice for
# 1080p x264 at high bitrates). Actual savings depend on source quality;
# treat the projection as an upper bound, not a guarantee.

set -uo pipefail

# ----------------------------- Config (env overridable) -----------------------------
ROOT="${1:-${ROOT:-}}"
EST_RATIO="${EST_RATIO:-0.42}"   # estimated output size as fraction of source (0.42 = ~58% smaller)
MIN_SRC_KBPS="${MIN_SRC_KBPS:-3000}"
MAX_W="${MAX_W:-1920}"
MAX_H="${MAX_H:-1080}"

# ----------------------------- Shared lib bootstrap --------------------------------
log(){ :; }   # no-op; classify() uses log() in hevc-lib.sh (it doesn't, but be safe)
source "${HEVC_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hevc-lib.sh}"

# ----------------------------- Platform shims --------------------------------------
case "$(uname -s)" in
  Darwin) stat_size(){ stat -f '%z' "$1" 2>/dev/null; } ;;
  *)      stat_size(){ stat -c '%s' "$1" 2>/dev/null; } ;;
esac

# ----------------------------- Self-check ------------------------------------------
if [ "${1:-}" = --selfcheck ]; then
  # verify estimate math: 1000 bytes * 0.4 ratio -> 400 out -> 600 reclaim (60%)
  _src=1000; _ratio=0.4
  _out=$(awk "BEGIN{printf \"%d\", $_src * $_ratio}")
  _rec=$(awk "BEGIN{printf \"%d\", $_src - $_out}")
  _pct=$(awk "BEGIN{printf \"%.0f\", 100 * ($_src - $_out) / $_src}")
  [ "$_out" = 400 ] || { echo "FAIL: estimated output should be 400, got $_out"; exit 1; }
  [ "$_rec" = 600 ] || { echo "FAIL: reclaim should be 600, got $_rec"; exit 1; }
  [ "$_pct" = 60  ] || { echo "FAIL: pct should be 60, got $_pct"; exit 1; }
  echo "hevc-estimate selfcheck OK"
  exit 0
fi

# ----------------------------- Probe -----------------------------------------------
# Sets V_CODEC V_W V_H V_TRC V_PRIM DUR SIZE EFFKBPS (mirrors hevc-convert.sh probe())
probe(){
  local f="$1" j
  j=$(ffprobe -v error -select_streams v:0 \
       -show_entries stream=codec_name,width,height,color_transfer,color_primaries \
       -show_entries format=duration,size -of default=nw=1 "$f" 2>/dev/null)
  V_CODEC=$(sed -n 's/^codec_name=//p' <<<"$j" | head -1)
  V_W=$(sed -n 's/^width=//p'         <<<"$j" | head -1)
  V_H=$(sed -n 's/^height=//p'        <<<"$j" | head -1)
  V_TRC=$(sed -n 's/^color_transfer=//p'  <<<"$j" | head -1)
  V_PRIM=$(sed -n 's/^color_primaries=//p' <<<"$j" | head -1)
  DUR=$(sed -n 's/^duration=//p'      <<<"$j" | head -1)
  SIZE=$(sed -n 's/^size=//p'         <<<"$j" | head -1)
  : "${V_W:=0}" "${V_H:=0}" "${SIZE:=0}"
  EFFKBPS=0
  if [ -n "${DUR:-}" ] && awk "BEGIN{exit !(${DUR:-0}>0)}"; then
    EFFKBPS=$(awk "BEGIN{printf \"%d\", ($SIZE*8)/$DUR/1000}")
  fi
}

# ----------------------------- Main scan -------------------------------------------
[ -n "$ROOT" ] || { echo "Usage: ROOT=/path/to/library $0  (or pass path as \$1)"; exit 1; }
[ -d "$ROOT" ] || { echo "ERROR: ROOT=$ROOT is not a directory"; exit 1; }

echo "hevc-estimate: scanning $ROOT"
echo "  EST_RATIO=$EST_RATIO  MIN_SRC_KBPS=$MIN_SRC_KBPS  MAX_W=${MAX_W}x${MAX_H}"
echo ""

total=0
convert_count=0
convert_bytes=0
skip_already=0
skip_hdr=0
skip_lowres=0
skip_lowbitrate=0
skip_unreadable=0

while IFS= read -r -d '' f; do
  total=$((total+1))
  probe "$f"
  if [ -z "$V_CODEC" ]; then
    skip_unreadable=$((skip_unreadable+1))
    continue
  fi
  decision=$(classify)
  case "$decision" in
    convert)
      convert_count=$((convert_count+1))
      convert_bytes=$(awk "BEGIN{printf \"%d\", $convert_bytes + ${SIZE:-0}}")
      ;;
    skip:already-hevc)  skip_already=$((skip_already+1)) ;;
    skip:hdr)           skip_hdr=$((skip_hdr+1)) ;;
    skip:lowres)        skip_lowres=$((skip_lowres+1)) ;;
    skip:lowbitrate)    skip_lowbitrate=$((skip_lowbitrate+1)) ;;
    *)                  skip_unreadable=$((skip_unreadable+1)) ;;
  esac
done < <(find "$ROOT" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' \) -print0 2>/dev/null | sort -z)

est_out=$(awk "BEGIN{printf \"%d\", $convert_bytes * $EST_RATIO}")
reclaim=$(awk "BEGIN{printf \"%d\", $convert_bytes - $est_out}")
reclaim_pct=$(awk "BEGIN{if($convert_bytes>0) printf \"%.1f\", 100*($convert_bytes-$est_out)/$convert_bytes; else print 0}")

echo "========================================"
echo " hevc-estimate summary"
echo "========================================"
printf "  Total files scanned   : %d\n"   "$total"
printf "  Convert candidates    : %d\n"   "$convert_count"
printf "  Skip (already HEVC)   : %d\n"   "$skip_already"
printf "  Skip (HDR)            : %d\n"   "$skip_hdr"
printf "  Skip (low-res <1080p) : %d\n"   "$skip_lowres"
printf "  Skip (low-bitrate)    : %d\n"   "$skip_lowbitrate"
printf "  Skip (unreadable)     : %d\n"   "$skip_unreadable"
echo "----------------------------------------"
printf "  Current size (convert): %s\n"   "$(hsize "$convert_bytes")"
printf "  Estimated output      : %s  (ratio %.2f)\n" "$(hsize "$est_out")" "$EST_RATIO"
printf "  Projected reclaim     : %s  (%.1f%%)\n" "$(hsize "$reclaim")" "$reclaim_pct"
echo "========================================"
