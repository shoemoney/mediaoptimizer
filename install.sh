#!/usr/bin/env bash
# install.sh — symlink the CLIs onto PATH and seed farm.conf. Run from a checkout:
#   git clone https://git.shoemoney.ai/shoemoney/mediaoptimizer && cd mediaoptimizer && ./install.sh
# ponytail: no brew tap — it's a handful of shell scripts; a symlink + a config copy IS the
# install. Add a tap only if someone wants `brew upgrade` semantics.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/scripts" && pwd)"
BIN="${BIN:-$HOME/.local/bin}"; mkdir -p "$BIN"

command -v ffmpeg >/dev/null 2>&1 || echo "⚠️  ffmpeg not found — install it (brew install ffmpeg) before converting"

for s in hevcctl farm-deploy; do
  ln -sf "$HERE/$s.sh" "$BIN/$s" && echo "linked $BIN/$s -> $s.sh"
done

if [ ! -f "$HERE/farm.conf" ]; then
  cp "$HERE/farm.conf.example" "$HERE/farm.conf"
  echo "seeded $HERE/farm.conf — edit it (NAS, REMOTE_ROOT, HOSTS, SLICE) before deploying"
fi

case ":$PATH:" in *":$BIN:"*) ;; *) echo "➕ add to your shell rc:  export PATH=\"$BIN:\$PATH\"";; esac
echo "✅ installed. Next:  edit scripts/farm.conf  →  farm-deploy check  →  farm-deploy all"
