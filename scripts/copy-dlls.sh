#!/usr/bin/env bash
# Copy the non-system DLLs a Windows build needs next to the .exe.
# Walks the import tables recursively (SDL2.dll -> SDL3.dll with sdl2-compat)
# and looks the DLLs up in the usual mingw sysroots (Fedora and Debian/Ubuntu).
#
#   scripts/copy-dlls.sh build-windows/buyo-buyo.exe dist/buyo-buyo-x.y.z-windows
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

EXE="$1"
DEST="$2"
OBJDUMP="${OBJDUMP:-x86_64-w64-mingw32-objdump}"
SEARCH=(
  /usr/x86_64-w64-mingw32/sys-root/mingw/bin   # Fedora mingw64-* packages
  /usr/x86_64-w64-mingw32/bin                  # Debian/Ubuntu, SDL2 mingw tarball
  /usr/x86_64-w64-mingw32/lib
  /mingw64/bin                                 # MSYS2
)
for d in /usr/lib/gcc/x86_64-w64-mingw32/*; do SEARCH+=("$d"); done

imports() {
  "$OBJDUMP" -p "$1" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p'
}

find_dll() {
  local name="$1" d
  for d in "${SEARCH[@]}"; do
    [ -f "$d/$name" ] && { echo "$d/$name"; return 0; }
  done
  return 1
}

declare -A seen=()
queue=("$EXE")
while [ ${#queue[@]} -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")
  deps="$(imports "$file")"
  # DLLs loaded at runtime by name don't show up in import tables: sdl2-compat's
  # SDL2.dll loads SDL3.dll with LoadLibrary
  if grep -qa "SDL3.dll" "$file" 2>/dev/null; then deps="$deps"$'\n'"SDL3.dll"; fi
  while read -r dll; do
    [ -n "$dll" ] || continue
    key="${dll,,}"
    [ -n "${seen[$key]:-}" ] && continue
    seen[$key]=1
    if path="$(find_dll "$dll")"; then
      cp -u "$path" "$DEST/"
      echo "  bundled $dll"
      queue+=("$path")
    fi # not found: a Windows system DLL (KERNEL32, USER32, ...)
  done <<<"$deps"
done
