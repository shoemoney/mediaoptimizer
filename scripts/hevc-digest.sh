#!/usr/bin/env bash
# hevc-digest.sh — daily savings digest; reads the durable SAVINGS ledger and
# posts a last-Nh summary to ntfy (or prints to stdout if NTFY_URL is unset).
#
# Env:
#   SAVINGS         path to local ledger file (default: ./SAVINGS)
#   NAS             ssh target for remote ledger (e.g. user@host), optional
#   SAVINGS_REMOTE  remote ledger path (required when NAS is set)
#   SINCE_HOURS     window in hours (default: 24)
#   NTFY_URL        ntfy endpoint; empty = print to stdout
#
# Ledger format (tab-separated, appended by record_savings):
#   epoch_ts \t hosttag \t before_bytes \t after_bytes \t label
set -uo pipefail

# -- selfcheck -----------------------------------------------------------
if [ "${1:-}" = --selfcheck ]; then
  tf=$(mktemp)
  now=$(date +%s)
  old=100000
  # two rows inside the window, one clearly outside
  printf '%s\thost1\t1000000000\t420000000\tfile1\n' "$now"     >>"$tf"
  printf '%s\thost2\t2000000000\t900000000\tfile2\n' "$now"     >>"$tf"
  printf '%s\thost3\t5000000000\t1000000000\told-file\n' "$old" >>"$tf"

  cutoff=$(( now - 24*3600 ))
  result=$(awk -F'\t' -v cutoff="$cutoff" '
    $1+0 >= cutoff { n++; b+=$3; a+=$4 }
    END {
      if (n == 0) { print "NODATA"; exit }
      reclaim = b - a
      pct = 100 * reclaim / b
      printf "%d\t%s\t%s\t%.0f\n", n, b, a, pct
    }
  ' "$tf")

  count=$(printf '%s' "$result" | cut -f1)
  before=$(printf '%s' "$result" | cut -f2)
  after=$(printf '%s' "$result" | cut -f3)
  pct=$(printf '%s' "$result" | cut -f4)

  rm -f "$tf"

  [ "$count" = "2" ]                 || { echo "FAIL: expected 2 rows, got $count"; exit 1; }
  [ "$before" = "3000000000" ]       || { echo "FAIL: before bytes wrong: $before"; exit 1; }
  [ "$after"  = "1320000000" ]       || { echo "FAIL: after bytes wrong: $after"; exit 1; }
  [ "$pct"    = "56" ]               || { echo "FAIL: pct wrong: $pct (expected 56)"; exit 1; }

  echo "hevc-digest selfcheck OK"
  exit 0
fi

# -- config --------------------------------------------------------------
SINCE_HOURS="${SINCE_HOURS:-24}"
NTFY_URL="${NTFY_URL:-}"
SAVINGS="${SAVINGS:-$(dirname "$0")/../SAVINGS}"
# fallback: look for SAVINGS next to the script, then cwd
[ -f "$SAVINGS" ] || SAVINGS="$(pwd)/SAVINGS"

# fetch ledger
ledger_tmp=""
if [ ! -f "$SAVINGS" ] && [ -n "${NAS:-}" ] && [ -n "${SAVINGS_REMOTE:-}" ]; then
  ledger_tmp=$(mktemp)
  if ! ssh "$NAS" "cat '$SAVINGS_REMOTE'" >"$ledger_tmp" 2>/dev/null; then
    echo "hevc-digest: failed to fetch ledger from $NAS:$SAVINGS_REMOTE" >&2
    rm -f "$ledger_tmp"
    exit 1
  fi
  SAVINGS="$ledger_tmp"
fi

cleanup(){ rm -f "${ledger_tmp:-}"; }
trap cleanup EXIT

# -- inline byte humanizer -----------------------------------------------
hsize(){ awk -v b="${1:-0}" 'BEGIN{
  u="B"; s=b; split("K M G T",a)
  for(i=1;i<=4&&s>=1024;i++){s/=1024; u=a[i]"B"}
  printf "%.2f%s", s, u
}'; }

# -- compute window cutoff -----------------------------------------------
now=$(date +%s)
cutoff=$(( now - SINCE_HOURS * 3600 ))

# -- handle missing/empty ledger -----------------------------------------
if [ ! -s "${SAVINGS:-}" ]; then
  msg="hevc-farm — no conversions in the last ${SINCE_HOURS}h (ledger empty or missing)"
  if [ -n "$NTFY_URL" ]; then
    curl -fsS -m 8 -H "Title: hevc-farm" -d "$msg" "$NTFY_URL" >/dev/null 2>&1 || true
  else
    echo "$msg"
  fi
  exit 0
fi

# -- aggregate -----------------------------------------------------------
read -r count before after pct < <(awk -F'\t' -v cutoff="$cutoff" '
  $1+0 >= cutoff { n++; b+=$3; a+=$4 }
  END {
    if (n == 0) { print "0 0 0 0"; exit }
    reclaim = b - a
    pct = (b > 0) ? 100 * reclaim / b : 0
    printf "%d %.0f %.0f %.0f\n", n, b, a, pct
  }
' "$SAVINGS")

# -- format digest -------------------------------------------------------
if [ "${count:-0}" -eq 0 ]; then
  msg="📦 hevc-farm — no conversions in the last ${SINCE_HOURS}h"
else
  b_human=$(hsize "$before")
  a_human=$(hsize "$after")
  saved=$(hsize "$(( before - after ))")
  msg="📦 hevc-farm — last ${SINCE_HOURS}h: ${count} files, ${b_human} → ${a_human} (saved ${saved}, ${pct}%)"
fi

# -- output --------------------------------------------------------------
if [ -n "$NTFY_URL" ]; then
  curl -fsS -m 8 -H "Title: hevc-farm" -d "$msg" "$NTFY_URL" >/dev/null 2>&1 || true
else
  echo "$msg"
fi
