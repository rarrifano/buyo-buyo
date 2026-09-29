# Buyo Buyo - C + SDL2 + Lua 5.4 (vendored)
# SPDX-License-Identifier: GPL-2.0-or-later
#
#   make                 build ./build/buyo-buyo (Linux, macOS, MSYS2/MinGW)
#   make run             build and run
#   make test            self-tests + headless CPU match + netplay loopback test
#   make debug           ASan/UBSan build in ./build-debug
#   make dist            package binary + game + content + docs into ./dist
#   make windows         cross-compile a Windows build (needs mingw64; see the podman image)
#   make LUA=system      link against the system Lua 5.4 instead of third_party/lua
#   make format          reformat src/*.{c,h} (clang-format) and game/,content/ (stylua)
#   make format-check    same, but only check + fail (used by CI)
#   make lint            luacheck (game/, content/) + clang-tidy (src/)
#   make lint-lua        luacheck only
#   make lint-c          clang-tidy only
#   make install-hooks   install scripts/pre-commit as .git/hooks/pre-commit
#
#   podman: scripts/podman.sh build|test|windows|run|shell  (no host packages needed)

CC         ?= cc
PKG_CONFIG ?= pkg-config
BUILD      ?= build
LUA        ?= vendored
OPT        ?= -O2 -g

# ---- platform ---------------------------------------------------------
ifneq ($(findstring mingw,$(CC))$(filter Windows_NT,$(OS)),)
  TARGET_OS := windows
else ifeq ($(shell uname -s 2>/dev/null),Darwin)
  TARGET_OS := macos
else
  TARGET_OS := linux
endif

ifeq ($(TARGET_OS),windows)
  EXE           := .exe
  PLATFORM_LIBS := -lws2_32 -static-libgcc
  LUA_DEFS      :=
else
  EXE           :=
  PLATFORM_LIBS := -lm
  LUA_DEFS      := -DLUA_USE_POSIX
endif
TARGET := $(BUILD)/buyo-buyo$(EXE)

# ---- dependencies -----------------------------------------------------
# Targets that never compile anything (formatting/lint-lua/housekeeping)
# shouldn't require SDL2 to be installed. `windows` re-invokes $(MAKE) with
# a cross PKG_CONFIG for the actual build, so it doesn't need the host's
# native SDL2 either.
NO_SDL_GOALS   := format format-check lint-lua install-hooks clean distclean windows
NEEDS_SDL      := $(if $(MAKECMDGOALS),$(filter-out $(NO_SDL_GOALS),$(MAKECMDGOALS)),1)

SDL_CFLAGS := $(shell $(PKG_CONFIG) --cflags sdl2 2>/dev/null)
SDL_LIBS   := $(shell $(PKG_CONFIG) --libs sdl2 2>/dev/null)
ifeq ($(SDL_LIBS),)
  ifneq ($(strip $(NEEDS_SDL)),)
    $(error SDL2 development files not found via $(PKG_CONFIG) (Fedora: sdl2-compat-devel, Debian/Ubuntu: libsdl2-dev, macOS: brew install sdl2 pkg-config, MSYS2: mingw-w64-x86_64-SDL2))
  endif
endif

ifeq ($(LUA),system)
  LUA_PKG    := $(firstword $(foreach p,lua5.4 lua-5.4 lua54 lua,$(shell $(PKG_CONFIG) --exists $(p) && echo $(p))))
  LUA_CFLAGS := $(shell $(PKG_CONFIG) --cflags $(LUA_PKG))
  LUA_LIBS   := $(shell $(PKG_CONFIG) --libs $(LUA_PKG))
  LUA_OBJ    :=
else
  LUA_CFLAGS := -Ithird_party/lua
  LUA_LIBS   :=
  LUA_SRC    := $(wildcard third_party/lua/*.c)
  LUA_OBJ    := $(LUA_SRC:third_party/lua/%.c=$(BUILD)/lua/%.o)
endif

# ---- sources ----------------------------------------------------------
ENGINE_SRC := $(filter-out src/stb_impl.c src/stb_vorbis_impl.c,$(wildcard src/*.c))
ENGINE_OBJ := $(ENGINE_SRC:src/%.c=$(BUILD)/obj/%.o)
STB_OBJ    := $(BUILD)/obj/stb_impl.o $(BUILD)/obj/stb_vorbis_impl.o

WARN   := -Wall -Wextra -Wshadow -Wno-unused-parameter
CFLAGS += -std=gnu11 $(OPT) -MMD -MP
INC    := -Isrc -Ithird_party/stb $(LUA_CFLAGS) $(SDL_CFLAGS)
LDLIBS += $(LUA_LIBS) $(SDL_LIBS) $(PLATFORM_LIBS)

.PHONY: all run debug test clean distclean dist windows format format-check lint install-hooks

all: $(TARGET)

$(TARGET): $(ENGINE_OBJ) $(STB_OBJ) $(LUA_OBJ)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD)/obj/%.o: src/%.c | $(BUILD)/obj
	$(CC) $(CFLAGS) $(WARN) $(INC) -c $< -o $@

# third-party code: no warnings, never our business
$(BUILD)/obj/stb_impl.o $(BUILD)/obj/stb_vorbis_impl.o: $(BUILD)/obj/%.o: src/%.c | $(BUILD)/obj
	$(CC) $(CFLAGS) -w $(INC) -c $< -o $@

$(BUILD)/lua/%.o: third_party/lua/%.c | $(BUILD)/lua
	$(CC) $(CFLAGS) -w $(LUA_DEFS) -c $< -o $@

$(BUILD)/obj $(BUILD)/lua:
	mkdir -p $@

run: $(TARGET)
	./$(TARGET)

debug:
	$(MAKE) BUILD=build-debug OPT="-O0 -g3 -fsanitize=address,undefined -fno-omit-frame-pointer" \
	        LDFLAGS="-fsanitize=address,undefined"

test: $(TARGET)
	./$(TARGET) --headless --frames 1 -- --test
	./$(TARGET) --headless --frames 1 -- --check-content
	./$(TARGET) --headless --frames 20000 -- --mode watch --level 3 --level2 4 --seed 7 \
	            --first-to 2 --skip-draw --turbo 4 --quit-at-end
	./scripts/netplay-test.sh ./$(TARGET)

# ---- packaging --------------------------------------------------------
VERSION  := $(shell grep -m1 'define BUYO_VERSION' src/engine.h | cut -d '"' -f2)
DISTNAME := buyo-buyo-$(VERSION)-$(TARGET_OS)
DISTDIR  := dist/$(DISTNAME)

dist: $(TARGET)
	rm -rf $(DISTDIR) && mkdir -p $(DISTDIR)
	cp $(TARGET) $(DISTDIR)/
	cp -r game content docs LICENSE README.md $(DISTDIR)/
	rm -rf $(DISTDIR)/game/tests
	@if [ "$(TARGET_OS)" = windows ]; then ./scripts/copy-dlls.sh $(TARGET) $(DISTDIR); fi
	cd dist && rm -f $(DISTNAME).zip && (zip -qr $(DISTNAME).zip $(DISTNAME) 2>/dev/null || tar czf $(DISTNAME).tar.gz $(DISTNAME))
	@echo "packaged: $$(ls -1 dist/$(DISTNAME).* | head -1)"

# Cross-compile from Linux. Fedora ships x86_64-w64-mingw32-pkg-config; on
# Debian/Ubuntu (and with the official SDL2 mingw tarball) fall back to plain
# pkg-config pointed at the mingw sysroot, with --define-prefix so .pc files
# that were built for another prefix still resolve.
MINGW_PKG_CONFIG := $(or $(shell command -v x86_64-w64-mingw32-pkg-config 2>/dev/null),\
  PKG_CONFIG_LIBDIR=/usr/x86_64-w64-mingw32/lib/pkgconfig pkg-config --define-prefix)

windows:
	$(MAKE) BUILD=build-windows CC=x86_64-w64-mingw32-gcc PKG_CONFIG="$(MINGW_PKG_CONFIG)" dist

clean:
	rm -rf $(BUILD) build-debug build-windows

distclean: clean
	rm -rf dist .cache

# ---- linters / formatters ---------------------------------------------
C_SRC   := $(wildcard src/*.c src/*.h)
LUA_SRC_FILES := $(shell find game content -name '*.lua')

format:
	clang-format -i $(C_SRC)
	stylua $(LUA_SRC_FILES)

format-check:
	clang-format --dry-run --Werror $(C_SRC)
	stylua --check $(LUA_SRC_FILES)

lint: lint-lua lint-c

lint-lua:
	luacheck game content

lint-c:
	clang-tidy $(filter-out src/stb_impl.c src/stb_vorbis_impl.c,$(wildcard src/*.c)) -- $(INC)

install-hooks:
	install -m 755 scripts/pre-commit .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit"

-include $(ENGINE_OBJ:.o=.d) $(STB_OBJ:.o=.d)
