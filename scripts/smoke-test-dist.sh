#!/usr/bin/env bash
# Smoke-test an unpacked release package the way a player would use it:
# the packaged binary runs from outside the package (so it must find game/
# and content/ next to itself), starts, validates every built-in item and
# plays a whole CPU vs CPU match.
#
#   scripts/smoke-test-dist.sh dist/buyo-buyo-v1.2.0-linux
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
PKG="$(cd "$1" && pwd)"
BIN="$PKG/buyo-buyo"
[ -f "$BIN.exe" ] && BIN="$BIN.exe"

run() {
  if [[ "$BIN" == *.exe ]]; then
    # only the package's own DLLs and Windows' may be found: a DLL the zip
    # forgot must fail here, not on a player's machine
    PATH="/c/Windows/System32:/c/Windows" "$BIN" "$@"
  else
    "$BIN" "$@"
  fi
}

cd "$(mktemp -d)"
help="$(run --help)"
echo "${help%%$'\n'*}"
run --headless --frames 1 -- --check-content --no-user-mods
run --headless --frames 20000 -- --mode watch --level 3 --level2 4 --seed 7 \
  --first-to 1 --skip-draw --turbo 4 --quit-at-end --no-user-mods
echo "smoke test OK: $(basename "$PKG")"
