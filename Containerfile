# Buyo Buyo - reproducible dev/build environment (Fedora + SDL2 + Lua 5.4)
#
#   ./scripts/podman.sh image     # build this image
#   ./scripts/podman.sh build     # compile the game inside the container
#   ./scripts/podman.sh run       # run the game inside the container (Wayland/X11 + PipeWire passthrough)
#   ./scripts/podman.sh shell     # interactive dev shell
#
# Match FEDORA_VERSION to the host (rpm -E %fedora) so binaries built here
# also run natively on the host.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

LABEL org.opencontainers.image.title="buyo-buyo-dev" \
      org.opencontainers.image.description="Build + run environment for Buyo Buyo (C / SDL2 / Lua)"

# Toolchain + libraries, debugging tools, and the runtime bits SDL loads
# dynamically (Wayland/X11 video, PipeWire/Pulse audio, Mesa GPU drivers).
RUN dnf -y install --setopt=install_weak_deps=False \
        gcc make pkgconf-pkg-config binutils curl \
        sdl2-compat-devel lua-devel lua \
        gdb valgrind strace clang-tools-extra \
        luarocks unzip \
        mesa-dri-drivers mesa-libEGL mesa-libGL mesa-libgbm libdrm \
        libdecor libxkbcommon \
        libwayland-client libwayland-cursor libwayland-egl \
        libX11 libXext libXcursor libXi libXrandr libXfixes libXScrnSaver \
        pipewire-libs pulseaudio-libs alsa-lib \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Sanitizer runtimes for `make debug` (ASan + UBSan). Separate layer so the
# big one above stays cached.
RUN dnf -y install --setopt=install_weak_deps=False libasan libubsan \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Lua linter/formatter (same tools the lint/format CI jobs use).
RUN luarocks install luacheck \
    && curl -fsSL -o /tmp/stylua.zip \
        https://github.com/JohnnyMorganz/StyLua/releases/latest/download/stylua-linux-x86_64.zip \
    && unzip -o /tmp/stylua.zip -d /usr/local/bin && chmod +x /usr/local/bin/stylua \
    && rm /tmp/stylua.zip

# Windows cross-compilation (`make windows`): mingw64 gcc + SDL2 (sdl2-compat
# on top of SDL3) + zip for packaging. Last layer so the ones above stay cached.
RUN dnf -y install --setopt=install_weak_deps=False \
        mingw64-gcc mingw64-sdl2-compat mingw64-SDL3 mingw64-winpthreads-static zip \
    && dnf clean all \
    && rm -rf /var/cache/dnf

ENV LANG=C.UTF-8
WORKDIR /src
CMD ["make"]
