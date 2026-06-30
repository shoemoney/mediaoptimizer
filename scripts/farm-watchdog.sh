#!/opt/homebrew/bin/bash
# farm-watchdog.sh — detect & auto-heal a silently-dead HEVC farm node (#1 active cure + #14 heartbeat).
#
# The launchd daemons have KeepAlive=true, yet 3 of 4 nodes still went dark and stayed dead
# ~11h unnoticed — KeepAlive only revives a *crash*, not a job that got booted-out / throttled /
# errored. This runs from cron/launchd on the CONTROL box (the laptop), checks each node's
# launchd job state directly, RE-BOOTSTRAPS any that aren't running (the active fix KeepAlive
# can't give), alerts via ntfy on any unhealthy node, and pings a heartbeat URL ONLY when all
# nodes are healthy — so silence on the heartbeat side alarms even if this watchdog itself dies.
#
# Run every ~10 min:  */10 * * * * /Users/shoemoney/projects/mediaoptimizer/scripts/farm-watchdog.sh
# Dry run (no kickstart/alert, just report what it sees):  DRY=1 ./farm-watchdog.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${FARM_CONF:-$HERE/farm.conf}"            # provides HOSTS=(...) and LABEL=...
: "${HOSTS:?farm.conf must define HOSTS}" "${LABEL:?farm.conf must define LABEL}"
SSH="${SSH:-ssh -o ConnectTimeout=8 -o BatchMode=yes}"
NTFY_URL="${NTFY_URL:-}"            # e.g. https://ntfy.sh/shoemoney-hevc (or self-hosted); empty = log only
HEARTBEAT_URL="${HEARTBEAT_URL:-}" # e.g. https://hc-ping.com/<uuid>; pinged only when ALL healthy (dead-man switch)
DRY="${DRY:-0}"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

alert(){ echo "[watchdog] $*" >&2; { [ "$DRY" = 1 ] || [ -z "$NTFY_URL" ]; } && return 0; curl -fsS -m 8 -H "Title: hevc-farm" -d "$*" "$NTFY_URL" >/dev/null 2>&1 || true; }

# launchd job state on a node: "running" = good. Anything else (waiting/errored/missing) means act.
node_state(){ $SSH "$1" "sudo launchctl print system/$LABEL 2>/dev/null | awk '/state = /{print \$3; exit}'" </dev/null 2>/dev/null || true; }
node_proc(){  $SSH "$1" "pgrep -f farm-worker.sh >/dev/null 2>&1 && echo up || echo down" </dev/null 2>/dev/null || echo down; }

unhealthy=0; revived=(); dead=()
for h in "${HOSTS[@]}"; do
  st=$(node_state "$h"); proc=$(node_proc "$h")
  if [ "$st" = running ] && [ "$proc" = up ]; then continue; fi
  unhealthy=$((unhealthy+1))
  if [ "$DRY" = 1 ]; then echo "[watchdog] WOULD revive $h (state='${st:-missing}' proc=$proc)"; continue; fi
  # active cure: kickstart a loaded-but-stuck job; if it was booted out entirely, bootstrap from the plist
  $SSH "$h" "sudo launchctl kickstart -k system/$LABEL 2>/dev/null || sudo launchctl bootstrap system $PLIST 2>/dev/null" </dev/null >/dev/null 2>&1 || true
  sleep 2
  if [ "$(node_state "$h")" = running ]; then revived+=("$h"); alert "revived $h (was state='${st:-missing}' proc=$proc)"
  else dead+=("$h"); alert "FAILED to revive $h (state='${st:-missing}') — needs hands"; fi
done

if [ "$unhealthy" -eq 0 ]; then
  echo "[watchdog] all ${#HOSTS[@]} nodes healthy"
  [ "$DRY" = 1 ] || [ -z "$HEARTBEAT_URL" ] || curl -fsS -m 8 "$HEARTBEAT_URL" >/dev/null 2>&1 || true   # #14
else
  echo "[watchdog] $unhealthy unhealthy | revived: ${revived[*]:-none} | still-dead: ${dead[*]:-none}"
  # deliberately DO NOT ping heartbeat when degraded → the heartbeat monitor alarms on the silence
fi
