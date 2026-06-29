#!/usr/bin/env bash
# hevc-lib.sh — shared logic for hevc-convert.sh (QSV, in-container) and
# farm-worker.sh (VideoToolbox, over ssh). Sourced by both AFTER each defines
# log() and its config vars. Keeping the drift-prone bits (classify/scale/verify/
# size + state compaction + savings ledger) in one place means a fix lands once.
#
# Globals it reads (set by the caller's probe + config): V_CODEC V_W V_H V_TRC
# V_PRIM EFFKBPS DUR  MIN_SRC_KBPS MAX_W MAX_H  and writes SCALE_W SCALE_H.

# human-readable bytes — pure awk so it's identical on GNU/Linux and macOS
hsize(){ awk -v b="${1:-0}" 'BEGIN{u="B";s=b;split("K M G T",a);for(i=1;i<=4&&s>=1024;i++){s/=1024;u=a[i]"B"}printf "%.1f%s",s,u}'; }

# decide from probed vars -> echo "convert" or "skip:<reason>"
classify(){
  case "$V_CODEC" in hevc|h265|av1) echo "skip:already-hevc"; return;; esac
  case "$V_TRC"   in smpte2084|arib-std-b67) echo "skip:hdr"; return;; esac
  case "$V_PRIM"  in bt2020|bt2020nc|bt2020c) echo "skip:hdr"; return;; esac
  { [ "$V_W" -ge 1920 ] 2>/dev/null || [ "$V_H" -ge 1080 ] 2>/dev/null; } || { echo "skip:lowres"; return; }
  [ "${EFFKBPS:-0}" -lt "$MIN_SRC_KBPS" ] && { echo "skip:lowbitrate"; return; }
  echo "convert"
}

# only-downscale to fit MAX_WxMAX_H, keep AR, even dims -> sets SCALE_W SCALE_H ("" = no scale)
calc_scale(){
  SCALE_W=""; SCALE_H=""
  awk "BEGIN{exit !($V_W<=$MAX_W && $V_H<=$MAX_H)}" && return
  read -r SCALE_W SCALE_H < <(awk -v w="$V_W" -v h="$V_H" -v mw="$MAX_W" -v mh="$MAX_H" 'BEGIN{
    f=mw/w; g=mh/h; s=(f<g)?f:g; nw=int(w*s); nh=int(h*s);
    nw-=nw%2; nh-=nh%2; if(nw<2)nw=2; if(nh<2)nh=2; printf "%d %d", nw, nh}')
}

# verify a finished encode before we trash the original. tmp=LOCAL output file; uses DUR.
# Checks: non-empty, codec==hevc, duration within 1%, AND (the #3 hardening) actually
# decodes the first VERIFY_DECODE_SECS so a right-length-but-corrupt file can't pass.
verify(){
  local tmp="$1" oc od
  [ -s "$tmp" ] || { log "  verify: empty output"; return 1; }
  oc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$tmp" 2>/dev/null)
  [ "$oc" = hevc ] || { log "  verify: out codec=$oc (want hevc)"; return 1; }
  od=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$tmp" 2>/dev/null)
  awk -v a="${DUR:-0}" -v b="${od:-0}" 'BEGIN{d=a-b; if(d<0)d=-d; tol=a*0.01; if(tol<3)tol=3; exit !(b>0 && d<=tol)}' \
    || { log "  verify: duration mismatch src=$DUR out=$od"; return 1; }
  if [ "${VERIFY_DECODE_SECS:-30}" -gt 0 ]; then
    ffmpeg -v error -xerror -nostdin -t "${VERIFY_DECODE_SECS}" -i "$tmp" -f null - 2>>"$LOG" \
      || { log "  verify: decode error within first ${VERIFY_DECODE_SECS}s"; return 1; }
  fi
  return 0
}

# compact a single-writer state.tsv in place: keep the LAST row per path (col1),
# preserving first-seen order. Bounds unbounded append growth (#4). Caller must
# guarantee single writer (flock / lock.d) — do NOT run on the shared NAS state.
compact_state(){
  local sf="${1:?compact_state needs a file}"; [ -s "$sf" ] || return 0
  local tmp="$sf.compact.$$"
  awk -F'\t' '{rows[$1]=$0; if(!($1 in seen)){seen[$1]=1; order[++n]=$1}}
              END{for(i=1;i<=n;i++)print rows[order[i]]}' "$sf" >"$tmp" 2>/dev/null \
    && mv "$tmp" "$sf" || rm -f "$tmp"
}

# append one row to the durable, never-rotated savings ledger (#2). Exact lifetime
# totals come from `awk` over this file regardless of log rotation.
# args: before_bytes after_bytes label   (writes to $SAVINGS)
record_savings(){
  [ -n "${SAVINGS:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${HOSTTAG:-local}" "$1" "$2" "$3" >>"$SAVINGS" 2>/dev/null || true
}

# print a one-line lifetime summary from a savings ledger; used by `hevcctl savings`
savings_report(){
  local sf="${1:?}"; [ -s "$sf" ] || { echo "no savings recorded yet ($sf)"; return 0; }
  awk -F'\t' '{b+=$3; a+=$4; n++} END{
    if(b<=0){print "ledger empty"; exit}
    printf "converted %d files: %.2f TB -> %.2f TB  (saved %.2f TB, %.0f%% smaller)\n",
      n, b/2^40, a/2^40, (b-a)/2^40, 100*(b-a)/b}' "$sf"
}

# ponytail: ONE runnable check for the non-trivial logic. `bash hevc-lib.sh --selfcheck`
if [ "${1:-}" = --selfcheck ]; then
  log(){ :; }; MIN_SRC_KBPS=3000; MAX_W=1920; MAX_H=1080
  V_CODEC=h264 V_TRC=bt709 V_PRIM=bt709 V_W=1920 V_H=1080 EFFKBPS=8000; [ "$(classify)" = convert ] || { echo "FAIL classify h264"; exit 1; }
  V_CODEC=hevc;  [ "$(classify)" = skip:already-hevc ] || { echo "FAIL classify hevc"; exit 1; }
  V_CODEC=h264 V_TRC=smpte2084; [ "$(classify)" = skip:hdr ] || { echo "FAIL classify hdr"; exit 1; }
  V_TRC=bt709 V_W=1280 V_H=720; [ "$(classify)" = skip:lowres ] || { echo "FAIL classify lowres"; exit 1; }
  V_W=1920 V_H=1080 EFFKBPS=1000; [ "$(classify)" = skip:lowbitrate ] || { echo "FAIL classify lowbitrate"; exit 1; }
  V_W=3840 V_H=2160; calc_scale; [ "$SCALE_W" = 1920 ] && [ "$SCALE_H" = 1080 ] || { echo "FAIL scale 4k->$SCALE_W:$SCALE_H"; exit 1; }
  V_W=1920 V_H=1080; calc_scale; [ -z "$SCALE_W" ] || { echo "FAIL scale 1080p should be no-op"; exit 1; }
  t=$(mktemp); printf 'a\t1\nb\t1\na\t2\n' >"$t"; compact_state "$t"
  [ "$(wc -l <"$t")" -eq 2 ] && [ "$(awk -F'\t' '$1=="a"{print $2}' "$t")" = 2 ] || { echo "FAIL compact_state"; rm -f "$t"; exit 1; }
  SAVINGS=$(mktemp); record_savings 1000 400 x; [ "$(savings_report "$SAVINGS" | grep -c '60% smaller')" -eq 1 ] || { echo "FAIL savings"; rm -f "$t" "$SAVINGS"; exit 1; }
  rm -f "$t" "$SAVINGS"; echo "hevc-lib selfcheck OK"
fi
