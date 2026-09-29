#!/usr/bin/env bash
# Podman dev environment for Buyo Buyo.
#
#   scripts/podman.sh image          build the dev image (Fedora + gcc + SDL2 + Lua 5.4)
#   scripts/podman.sh build [ARGS]   compile inside the container (make ARGS)
#   scripts/podman.sh test           rules self-test + headless CPU vs CPU match
#   scripts/podman.sh run [ARGS]     play inside the container (Wayland/X11, PipeWire/Pulse, GPU, pads)
#   scripts/podman.sh shell          interactive shell in the container
#   scripts/podman.sh make [ARGS]    any make target inside the container
#
# The sources are bind-mounted, the container runs as your own UID
# (--userns=keep-id), so build/ is owned by you and binaries run on the host too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${BUYO_IMAGE:-localhost/buyo-buyo-dev:latest}"
FEDORA_VERSION="${FEDORA_VERSION:-$(rpm -E %fedora 2>/dev/null || echo 44)}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

build_image() {
  echo ">> building $IMAGE (Fedora $FEDORA_VERSION)"
  podman build --build-arg FEDORA_VERSION="$FEDORA_VERSION" -t "$IMAGE" -f "$ROOT/Containerfile" "$ROOT"
}

ensure_image() {
  podman image exists "$IMAGE" || build_image
}

mkdir -p "$ROOT/.cache/xdg-data"

# common options: your UID inside, sources at /src, no SELinux relabeling of
# your checkout, settings/saves kept in .cache/ of the project
BASE=(--rm --init --userns=keep-id --security-opt label=disable
      -v "$ROOT:/src" -w /src
      -e HOME=/tmp -e XDG_DATA_HOME=/src/.cache/xdg-data)
[[ -t 0 && -t 1 ]] && BASE+=(-it)

# display, audio, GPU and gamepad passthrough for running the game
GUI=()
gui_opts() {
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  GUI=(-e XDG_RUNTIME_DIR=/tmp/xdg --ipc=host)
  if [[ -n "${WAYLAND_DISPLAY:-}" && -S "$rt/$WAYLAND_DISPLAY" ]]; then
    GUI+=(-v "$rt/$WAYLAND_DISPLAY:/tmp/xdg/$WAYLAND_DISPLAY" -e "WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
  fi
  if [[ -n "${DISPLAY:-}" && -d /tmp/.X11-unix ]]; then
    GUI+=(-v /tmp/.X11-unix:/tmp/.X11-unix:ro -e "DISPLAY=$DISPLAY")
    if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
      GUI+=(-v "$XAUTHORITY:/tmp/.Xauthority:ro" -e XAUTHORITY=/tmp/.Xauthority)
    fi
  fi
  [[ -S "$rt/pipewire-0" ]] && GUI+=(-v "$rt/pipewire-0:/tmp/xdg/pipewire-0")
  [[ -S "$rt/pulse/native" ]] && GUI+=(-v "$rt/pulse/native:/tmp/xdg/pulse/native"
                                       -e PULSE_SERVER=unix:/tmp/xdg/pulse/native)
  [[ -d /dev/dri ]] && GUI+=(--device /dev/dri --group-add keep-groups)
  [[ -d /dev/input ]] && GUI+=(-v /dev/input:/dev/input:ro)
  [[ -d /run/udev ]] && GUI+=(-v /run/udev:/run/udev:ro)
  for v in SDL_VIDEODRIVER SDL_VIDEO_DRIVER SDL_AUDIODRIVER SDL_AUDIO_DRIVER; do
    [[ -n "${!v:-}" ]] && GUI+=(-e "$v=${!v}")
  done
  return 0
}

cmd="${1:-help}"
[[ $# -gt 0 ]] && shift

case "$cmd" in
  image)
    build_image
    ;;
  build)
    ensure_image
    podman run "${BASE[@]}" "$IMAGE" make "$@"
    ;;
  make)
    ensure_image
    podman run "${BASE[@]}" "$IMAGE" make "$@"
    ;;
  test)
    ensure_image
    podman run "${BASE[@]}" "$IMAGE" make test
    ;;
  run)
    ensure_image
    [[ -x "$ROOT/build/buyo-buyo" ]] || podman run "${BASE[@]}" "$IMAGE" make
    gui_opts
    podman run "${BASE[@]}" "${GUI[@]}" "$IMAGE" ./build/buyo-buyo "$@"
    ;;
  shell)
    ensure_image
    gui_opts
    podman run "${BASE[@]}" "${GUI[@]}" "$IMAGE" bash
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
