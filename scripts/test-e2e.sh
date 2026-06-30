#!/usr/bin/env bash
# test-e2e.sh — real encode→verify smoke test for hevc-lib.sh.
# ponytail: this validates the decide/encode/verify wiring with a software
# encoder (libx265) on a synthetic 2s clip. Hardware (VideoToolbox/QSV) is
# explicitly NOT tested — that's the ceiling here, by design.
#
# Exit 0 always when ffmpeg or libx265 is absent (safe on a bare dev box);
# exit nonzero with a clear message on any encode or verify failure.
set -uo pipefail

# --- guard: ffmpeg required ---
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
  echo "e2e: ffmpeg not found — skipping (CI installs it)"
  exit 0
fi

# --- guard: libx265 required ---
if ! ffmpeg -hide_banner -loglevel error \
      -f lavfi -i color=c=black:s=64x64:d=0.1:r=5 \
      -c:v libx265 -f null - </dev/null >/dev/null 2>&1; then
  echo "e2e: libx265 encoder not available — skipping"
  exit 0
fi

TMPDIR_E2E=$(mktemp -d)
trap 'rm -rf "$TMPDIR_E2E"' EXIT

SRC="$TMPDIR_E2E/src.mp4"
OUT="$TMPDIR_E2E/out.mp4"

# Generate a ~2s H.264 test clip; fall back to mpeg4 if libx264 is missing.
if ffmpeg -hide_banner -loglevel error \
     -f lavfi -i "testsrc=size=320x240:rate=24:duration=2" \
     -c:v libx264 -pix_fmt yuv420p "$SRC" 2>/dev/null; then
  :
elif ffmpeg -hide_banner -loglevel error \
     -f lavfi -i "testsrc=size=320x240:rate=24:duration=2" \
     -c:v mpeg4 -pix_fmt yuv420p "$SRC" 2>/dev/null; then
  :
else
  echo "e2e: FAIL — could not generate source clip"
  exit 1
fi

# Probe source duration for the verify() tolerance check.
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC" 2>/dev/null)
if [ -z "$SRC_DUR" ] || [ "$SRC_DUR" = "N/A" ]; then
  echo "e2e: FAIL — could not probe source duration"
  exit 1
fi

# Encode to HEVC with libx265 (software; available on all CI runners with ffmpeg).
if ! ffmpeg -hide_banner -loglevel error \
     -i "$SRC" -c:v libx265 -tag:v hvc1 -c:a copy "$OUT" 2>/dev/null; then
  echo "e2e: FAIL — libx265 encode returned non-zero"
  exit 1
fi

# Set up the environment verify() needs, then source the shared lib.
# verify() appends decode errors to $LOG; point it at a temp file.
LOG="$TMPDIR_E2E/decode.log"
DUR="$SRC_DUR"
VERIFY_DECODE_SECS=1
TARGET_CODEC=hevc
log(){ :; }   # hevc-lib.sh expects a log() function to be defined by the caller

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/hevc-lib.sh
source "$SCRIPT_DIR/hevc-lib.sh"

# Run the shared verify() function against the real output file.
if ! verify "$OUT"; then
  echo "e2e: FAIL — verify() rejected the libx265 output"
  [ -s "$LOG" ] && cat "$LOG"
  exit 1
fi

# Belt-and-suspenders: confirm ffprobe also reports hevc codec.
OUT_CODEC=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name -of csv=p=0 "$OUT" 2>/dev/null)
if [ "$OUT_CODEC" != "hevc" ]; then
  echo "e2e: FAIL — output codec is '$OUT_CODEC', expected 'hevc'"
  exit 1
fi

echo "e2e: encode→verify OK"
