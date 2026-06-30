#!/usr/bin/env bash
# test.sh — zero-dep regression gate (#6). Syntax-checks every script and runs the lib +
# enqueue selfchecks that pin the bugs this project actually hit (stdin-eating, trash FIFO,
# state poison/compaction, quality tiers, path remap).
# ponytail: bats skipped on purpose — plain `bash -n` + assert selfchecks need no framework
# and run anywhere bash does. Add bats only if a contributor asks for TAP output.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
for f in *.sh; do
  bash -n "$f" && echo "syntax OK: $f" || { echo "SYNTAX FAIL: $f"; rc=1; }
done
bash hevc-lib.sh --selfcheck     || rc=1
bash hevc-enqueue.sh --selfcheck || rc=1
bash hevc-estimate.sh --selfcheck || rc=1
bash hevc-digest.sh --selfcheck  || rc=1
bash "$(dirname "$0")/test-e2e.sh" || rc=1
[ $rc = 0 ] && echo "✅ all tests pass" || echo "❌ tests failed"
exit $rc
