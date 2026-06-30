#!/usr/bin/env bash
# hevc-enqueue.sh — drop ONE media path onto the farm's import queue so the workers convert
# it within ~QUEUE_POLL_SECS instead of waiting for the hourly rescan (#16).
#
# Wire into Sonarr/Radarr: Settings → Connect → + → Custom Script, path = this file,
# triggers = On Import + On Upgrade. *arr sets the env vars read below.
# It runs INSIDE the *arr container, so QUEUE_FILE must be a path the container can see, and
# PATH_MAP rewrites the *arr container path to the NAS-host path the workers actually pull:
#   QUEUE_FILE=/tv/.hevc-queue  PATH_MAP=/tv=/mnt/tank/media/videos/TV  hevc-enqueue.sh
# Or call directly with a host path:
#   hevc-enqueue.sh /mnt/tank/media/videos/TV/Show/ep.mkv

# ponytail: the one non-trivial bit is the prefix rewrite — pin it.
if [ "${1:-}" = --selfcheck ]; then
  from=/tv; to=/mnt/tank/media/videos/TV; p=/tv/Show/ep.mkv; p="${p/#$from/$to}"
  [ "$p" = /mnt/tank/media/videos/TV/Show/ep.mkv ] || { echo "FAIL PATH_MAP rewrite -> $p"; exit 1; }
  echo "hevc-enqueue selfcheck OK"; exit 0
fi

set -euo pipefail
QUEUE_FILE="${QUEUE_FILE:-${REMOTE_ROOT:-/mnt/tank/media/videos/TV}/.hevc-queue}"

# *arr "Test" button fires eventtype=Test with no file — succeed quietly so the test passes.
case "${sonarr_eventtype:-${radarr_eventtype:-}}" in Test) echo "enqueue: test ok"; exit 0;; esac

p="${1:-${sonarr_episodefile_path:-${radarr_moviefile_path:-}}}"
[ -n "$p" ] || { echo "enqueue: no path (pass an arg or run from *arr On Import/Upgrade)"; exit 1; }

# optional containerprefix=hostprefix rewrite so the queue holds NAS-host paths
if [ -n "${PATH_MAP:-}" ]; then from=${PATH_MAP%%=*}; to=${PATH_MAP#*=}; p="${p/#$from/$to}"; fi

printf '%s\n' "$p" >> "$QUEUE_FILE"
echo "enqueued: $p -> $QUEUE_FILE"
