# Buyo Buyo

A small falling-block puzzle engine and game, written in C (SDL2) with the
game itself scripted in Lua 5.4. Deterministic simulation and rollback
netplay let two players compete online.

## Requirements

- A C compiler (`gcc`/`clang`), `make`, `pkg-config`
- SDL2 development files (Fedora: `sdl2-compat-devel`, Debian/Ubuntu:
  `libsdl2-dev`, macOS: `brew install sdl2 pkg-config`, MSYS2:
  `mingw-w64-x86_64-SDL2`)
- Lua 5.4 is vendored in `third_party/lua` by default (use `make LUA=system`
  to link against a system install instead)

## Build & run

```
make            # build ./build/buyo-buyo
make run        # build and run
make test       # self-tests + headless match + netplay loopback
```

Other useful targets:

```
make debug          # ASan/UBSan build in ./build-debug
make dist            # package binary + game + content into ./dist
make windows         # cross-compile for Windows (needs mingw64)
```

No podman/host packages? `scripts/podman.sh` builds a container image with
everything installed:

```
scripts/podman.sh build     # compile inside the container
scripts/podman.sh test      # run the test suite inside the container
scripts/podman.sh run       # play inside the container (X11/Wayland, audio, pads)
scripts/podman.sh shell     # interactive shell
```

A `.devcontainer/` config is also provided for VS Code / Dev Containers.

## Command line

Extra arguments after `--` are forwarded to the game:

```
--mods DIR                 extra content folder (repeatable)
--mode cpu|2p|watch        start a match directly (skips menus)
--game-mode ID             content mode for --mode (default: tsu)
--char1 ID --char2 ID --stage ID --level N --level2 N --first-to N --seed N
--host | --connect CODE    online: wait for / connect to a friend
--net-port N --net-bot LEVEL --net-sim LAG,JITTER,LOSS --no-stun
--export-skin ID FILE      write a skin's sheet as PNG
--check-content            validate all content and quit (exit code 1 on errors)
--test                     run the self-tests and quit
```

## Layout

- `src/` - engine in C (SDL2, audio, input, Lua bindings).
- `game/core/` - engine-agnostic helpers (scene, settings, sound, util).
- `game/puyo/` - simulation: board, rules, match, ai, sequence. Kept
  deterministic (integer math only) so rollback netplay works.
- `game/scenes/` - screens (title, versus, settings, online).
- `game/view/` - rendering (field, char, sprites, ui, fx, stage, skin).
- `game/net/` - rollback netplay.
- `game/tests/` - Lua self-tests (`--test`), run via `make test`.
- `content/` - data-driven mods: `modes/<name>/mode.lua`,
  `chars/<name>/char.lua`, `stages/<name>/stage.lua`, `skins/<name>/`,
  `music/<name>.lua`. Add new content by copying an existing folder.

## Contributing

See `AGENTS.md` for coding conventions, formatting (`make format`), and
linting (`make lint`). CI runs `make test` (Linux/macOS/Windows) and
lint/format checks on every push and pull request.

## License

GPL-2.0-or-later, see `LICENSE`.
