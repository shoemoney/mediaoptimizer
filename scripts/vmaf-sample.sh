#!/opt/homebrew/bin/bash
# vmaf-sample.sh — capture the VMAF baseline that was never measured (#5).
# Encodes a short sample of each given source at the current farm quality and reports the
# mean VMAF, so VMAF_MIN can be set from data instead of a guess. Read-only on your library
# (writes only to a temp dir). Local files only — point it at a few representative sources:
#   ./vmaf-sample.sh [-t secs] [-q quality] [-c hevc|av1] file1.mkv file2.mkv ...
set -uo pipefail
SECS="${SECS:-60}"; VT_QUALITY="${VT_QUALITY:-60}"; VT_CODEC="${VT_CODEC:-hevc}"
while getopts "t:q:c:" o; do case $o in t)SECS=$OPTARG;; q)VT_QUALITY=$OPTARG;; c)VT_CODEC=$OPTARG;; *)exit 2;; esac; done
shift $((OPTIND-1))
[ $# -ge 1 ] || { echo "usage: $0 [-t secs] [-q quality] [-c hevc|av1] file ..."; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found"; exit 1; }
ffmpeg -hide_banner -filters 2>/dev/null | grep -q libvmaf || { echo "this ffmpeg lacks libvmaf"; exit 1; }
sz(){ stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%-46s %7s %8s %8s %8s\n' FILE VMAF SRC_MB OUT_MB SMALLER
tot=0; n=0
for f in "$@"; do
  [ -f "$f" ] || { echo "skip (missing): $f"; continue; }
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null); dur=${dur%.*}; ss=$(( ${dur:-0} / 10 ))
  ref="$tmp/ref.mkv"; out="$tmp/out.mkv"; rm -f "$ref" "$out"
  # cut a clean SECS clip (from ~10% in, past intros), then encode IT so ref/dist align frame-for-frame
  ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$ss" -t "$SECS" -i "$f" -map 0:v:0 -c:v copy -an -sn "$ref" 2>/dev/null || { echo "skip (cut failed): $(basename "$f")"; continue; }
  tagv=(); [ "$VT_CODEC" = hevc ] && tagv=(-tag:v hvc1)
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$ref" -map 0:v:0 -c:v "${VT_CODEC}_videotoolbox" -q:v "$VT_QUALITY" "${tagv[@]}" "$out" 2>/dev/null || { echo "skip (encode failed): $(basename "$f")"; continue; }
  score=$(ffmpeg -nostdin -hide_banner -loglevel info -i "$out" -i "$ref" \
    -lavfi "[0:v]setpts=PTS-STARTPTS[d];[1:v]setpts=PTS-STARTPTS[r];[d][r]libvmaf" -f null - 2>&1 | sed -n 's/.*VMAF score: *//p' | tail -1)
  s=$(sz "$ref"); o=$(sz "$out"); pct=$(awk -v a="${s:-0}" -v b="${o:-0}" 'BEGIN{print a>0?int(100*(a-b)/a):0}')
  printf '%-46.46s %7s %8.1f %8.1f %7s%%\n' "$(basename "$f")" "${score:-n/a}" \
    "$(awk -v x=${s:-0} 'BEGIN{print x/2^20}')" "$(awk -v x=${o:-0} 'BEGIN{print x/2^20}')" "$pct"
  [ -n "$score" ] && { tot=$(awk -v t=$tot -v v=$score 'BEGIN{print t+v}'); n=$((n+1)); }
done
[ "$n" -gt 0 ] && awk -v t=$tot -v n=$n 'BEGIN{printf "\nmean VMAF over %d sample(s): %.2f   (>=95 transparent, 93-95 good, <90 visible loss)\n", n, t/n}'
