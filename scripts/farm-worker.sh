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
CLAIMS_REMOTE="${CLAIMS_REMOTE:-$REMOTE_ROOT/.hevc-claims}"   # per-file claim dirs (atomic mkdir) so 2 nodes don't both encode one file
CLAIM_TTL_MIN="${CLAIM_TTL_MIN:-180}"                          # steal/expire a claim older than this (covers a crashed node)
SAVINGS_REMOTE="${SAVINGS_REMOTE:-$REMOTE_ROOT/.hevc-savings.tsv}"  # shared durable before/after byte ledger
VT_QUALITY="${VT_QUALITY:-60}"                              # hevc_videotoolbox -q:v (1-100)
VT_CODEC="${VT_CODEC:-hevc}"                                # hevc | av1  (#12; av1_videotoolbox needs M3+)
TARGET_CODEC="${TARGET_CODEC:-$VT_CODEC}"                   # what verify() expects the output codec_name to be
VMAF_MIN="${VMAF_MIN:-0}"                                   # >0 enables the perceptual quality gate (#1; slow)
MAX_W="${MAX_W:-1920}"; MAX_H="${MAX_H:-1080}"              # only-downscale ceiling
MIN_SRC_KBPS="${MIN_SRC_KBPS:-3000}"                        # skip sources already leaner
MIN_GAIN_PCT="${MIN_GAIN_PCT:-8}"                           # output must be this % smaller
TRASH_NAME="${TRASH_NAME:-.hevc_trash}"
TRASH_CAP_GB="${TRASH_CAP_GB:-80}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-3}"
RESCAN_SECS="${RESCAN_SECS:-3600}"
QUEUE_REMOTE="${QUEUE_REMOTE:-$REMOTE_ROOT/.hevc-queue}"   # event-driven import queue (#16); *arr appends via hevc-enqueue.sh
QUEUE_POLL_SECS="${QUEUE_POLL_SECS:-60}"                    # how often to check the queue between full rescans
ONESHOT="${ONESHOT:-0}"; LIMIT="${LIMIT:-0}"; DRY_RUN="${DRY_RUN:-0}"; RETRY_FAILED="${RETRY_FAILED:-0}"
CONCURRENCY="${CONCURRENCY:-1}"          # parallel encodes per worker (Apple Silicon media engine handles 2-3)
{ [ "$LIMIT" -gt 0 ] || [ "$DRY_RUN" = 1 ]; } && CONCURRENCY=1   # keep tests deterministic / sequential
HOSTTAG="${HOSTTAG:-$(hostname -s)}"
SSH="${SSH:-ssh -o ConnectTimeout=10 -o BatchMode=yes}"
# State.tsv keys may use a different path namespace than our ssh/find paths: the probe
# container sees the library at a mount path (MEDIA_CANON) while the NAS host path is
# MEDIA_HOST. canon() maps host->canon so dedup against the shared state lines up.
# Default is identity (no remap) — set both in farm.conf if your container remaps paths.
MEDIA_HOST="${MEDIA_HOST:-/}"; MEDIA_CANON="${MEDIA_CANON:-/}"
canon(){ printf '%s' "${1/#$MEDIA_HOST/$MEDIA_CANON}"; }

mkdir -p "$WORK"
LOG="$WORK/farm.log"; STATE_LOCAL="$WORK/state.tsv"; touch "$STATE_LOCAL"
SAVINGS="${SAVINGS:-$WORK/savings.tsv}"   # durable, never-rotated before/after byte ledger
log(){ printf '%s [%s] %s\n' "$(date '+%F %T')" "$HOSTTAG" "$*" | tee -a "$LOG" >&2; }
# shared logic — hsize/classify/calc_scale/verify/compact_state/record_savings (co-located lib)
source "${HEVC_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hevc-lib.sh}"

# #12: av1_videotoolbox only exists on M3+ media engines (.4's M1 hard-fails). Probe once at
# startup and fall back to hevc so a mixed fleet can share one config without per-host tweaks.
if [ "$VT_CODEC" = av1 ] && ! codec_supported av1_videotoolbox; then
  log "av1_videotoolbox unusable on this box → falling back to hevc"; VT_CODEC=hevc; TARGET_CODEC=hevc
fi

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
  compact_state "$STATE_LOCAL"   # single-writer (lock.d) — safe to dedupe in place
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
# classify() and calc_scale() now live in hevc-lib.sh (sourced above)

# encode LOCAL src -> LOCAL tmp via VideoToolbox -> 0 ok
encode(){
  local src="$1" tmp="$2" fmt="$3"
  local maps=(-map 0:v:0 -map '0:a?') scodec=()
  if [ "$fmt" = matroska ]; then maps+=(-map '0:s?' -map '0:t?'); scodec=(-c:s copy)
  else maps+=(-map '0:s?'); scodec=(-c:s mov_text); fi
  local vf=(); [ -n "$SCALE_W" ] && vf=(-vf "scale=$SCALE_W:$SCALE_H:flags=lanczos")
  # hvc1 tag only applies to HEVC; av1 needs no codec tag. # ponytail: 2 codecs, branch when a 3rd lands
  local tagv=(); [ "$VT_CODEC" = hevc ] && tagv=(-tag:v hvc1)
  local enc=(-c:v "${VT_CODEC}_videotoolbox" -q:v "$VT_QUALITY" "${tagv[@]}" -c:a copy)
  local out=(-map_metadata 0 -f "$fmt" "$tmp")
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" "${vf[@]}" "${maps[@]}" "${enc[@]}" "${scodec[@]}" "${out[@]}" 2>>"${FERR:-$LOG}" && return 0
  log "  retrying without subtitles (incompatible sub codec)"; rm -f "$tmp"
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$src" "${vf[@]}" -map 0:v:0 -map '0:a?' -sn "${enc[@]}" "${out[@]}" 2>>"${FERR:-$LOG}" && return 0
  return 1
}
# verify() now lives in hevc-lib.sh (sourced above) — incl. the decode-sample check

# claim a file before pulling so two nodes never both encode it (#1). Atomic mkdir on
# the NAS; steal a claim older than CLAIM_TTL_MIN (crashed node). No explicit release:
# done files are skipped via state, failed files cool off for the TTL, and stale claim
# dirs are reaped at pass start — TTL expiry is the release.
# ponytail: mkdir-atomic on the common path; the stale-steal branch can race two nodes
# onto ONE stale file (rare, costs one duplicate encode) — fine vs a lease server.
claim(){  # remote-path -> 0 if we now own it
  { [ "$DRY_RUN" = 1 ] || [ "$LIMIT" -gt 0 ]; } && return 0   # tests: don't touch the NAS
  local k cd; k=$(printf '%s' "$1" | shasum 2>/dev/null | cut -c1-40)
  [ -n "$k" ] || return 0   # no hasher -> never block real work
  cd="$CLAIMS_REMOTE/$k"
  $SSH "$NAS" "mkdir -p ${CLAIMS_REMOTE@Q} 2>/dev/null; if mkdir ${cd@Q} 2>/dev/null; then echo OK; \
    elif [ -n \"\$(find ${cd@Q} -maxdepth 0 -mmin +${CLAIM_TTL_MIN} 2>/dev/null)\" ]; then \
    rm -rf ${cd@Q} 2>/dev/null; mkdir ${cd@Q} 2>/dev/null && echo OK; fi" </dev/null 2>/dev/null | grep -q OK
}
reap_claims(){  # drop stale/orphaned claim dirs so the dir doesn't grow forever
  { [ "$DRY_RUN" = 1 ] || [ "$LIMIT" -gt 0 ]; } && return 0
  $SSH "$NAS" "find ${CLAIMS_REMOTE@Q} -mindepth 1 -maxdepth 1 -type d -mmin +${CLAIM_TTL_MIN} -exec rm -rf {} + 2>/dev/null" </dev/null 2>/dev/null || true
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
  pick_quality   # per-resolution tier (#4); no-op at the default MAX_H=1080

  log "CONVERT $V_CODEC ${V_W}x${V_H} ${EFFKBPS}k -> ${VT_CODEC^^} q$VT_QUALITY ${SCALE_W:+(${SCALE_W}x${SCALE_H}) }$(hsize "$SIZE"): $base"
  if [ "$DRY_RUN" = 1 ]; then state_set "$rf" "dry-convert" "${V_W}x${V_H}"; PROCESSED=$((PROCESSED+1)); return; fi

  # only now pull the source (we know it converts)
  lsrc="$WORK/src.$BASHPID.$ext"; lout="$WORK/out.$BASHPID.$outext"
  FERR="$WORK/.ferr.$BASHPID"; : >"$FERR"   # #3: per-encode ffmpeg stderr ($BASHPID = concurrency-safe)
  if ! $SSH "$NAS" "cat ${rf@Q}" </dev/null >"$lsrc"; then log "  PULL FAILED: $base"; rm -f "$lsrc"; state_set "$rf" failed "pull"; return; fi

  local t0 t1; t0=$(date +%s)
  if ! encode "$lsrc" "$lout" "$fmt"; then log "  ENCODE FAILED: $base"; capture_fail "$rf" "$FERR"; rm -f "$lsrc" "$lout"; state_set "$rf" failed "encode"; return; fi
  if ! verify "$lout"; then log "  VERIFY FAILED: $base"; rm -f "$lsrc" "$lout"; state_set "$rf" failed "verify"; return; fi
  if ! vmaf_ok "$lout" "$lsrc"; then log "  VMAF FAILED: $base"; rm -f "$lsrc" "$lout"; state_set "$rf" failed "vmaf"; return; fi
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
    record_savings "$SIZE" "$osz" "$(basename "$final")"   # local ledger
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$HOSTTAG" "$SIZE" "$osz" "$(basename "$final")" \
      | $SSH "$NAS" "cat >> ${SAVINGS_REMOTE@Q}" 2>/dev/null || true   # shared ledger
  else
    log "  REPLACE FAILED: $base"; state_set "$rf" failed "replace"
  fi
  rm -f "$lsrc" "$lout"
}

# drain the event-driven import queue (#16): atomically grab queued paths (mv → .work so
# imports arriving mid-drain land in a fresh queue and aren't lost) and run each through the
# normal claim→process path. The atomic mv also means only ONE node wins the batch; the rest
# get an empty read. # ponytail: serial drain — fine for trickle imports; parallelize if a
# bulk re-import floods it. Assumes load_state ran (DONE populated).
drain_queue(){
  local work; work=$($SSH "$NAS" "f=${QUEUE_REMOTE@Q}; w=\"\$f.work.$BASHPID\"; [ -s \"\$f\" ] && mv \"\$f\" \"\$w\" && cat \"\$w\" && rm -f \"\$w\"" 2>/dev/null) || return 0
  [ -z "$work" ] && return 0
  local rf st
  while IFS= read -r rf; do [ -z "$rf" ] && continue
    st="${DONE[$(canon "$rf")]:-}"; { [ -n "$st" ] && [ "$st" != failed ]; } && { log "QUEUE skip(done): $(basename "$rf")"; continue; }
    claim "$rf" || { log "QUEUE skip(claimed): $(basename "$rf")"; continue; }
    log "QUEUE convert: $(basename "$rf")"; process "$rf"
  done <<< "$work"
}

run_pass(){
  load_state
  reap_claims
  drain_queue
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
    claim "$rf" || { log "SKIP(claimed by another node): $(basename "$rf")"; continue; }
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
  # poll the import queue between full rescans so *arr imports convert within ~QUEUE_POLL_SECS (#16)
  log "idle: full rescan in ${RESCAN_SECS}s, polling queue every ${QUEUE_POLL_SECS}s"
  slept=0
  while [ "$slept" -lt "$RESCAN_SECS" ]; do
    sleep "$QUEUE_POLL_SECS"; slept=$((slept+QUEUE_POLL_SECS))
    if $SSH "$NAS" "[ -s ${QUEUE_REMOTE@Q} ]" 2>/dev/null; then load_state; drain_queue; fi
  done
done
