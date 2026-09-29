# Agent notes

Buyo Buyo: a small C + SDL2 engine (`src/`) driving a Lua 5.4 game (`game/`,
`content/`). Keep changes minimal and follow existing patterns.

## Build & test

```
make            # build ./build/buyo-buyo
make run
make test       # self-tests + headless match + netplay loopback
```

Run `make test` before submitting changes that touch `src/` or `game/`.

## Lint & format

```
make format         # clang-format src/*.{c,h}; stylua game/, content/
make format-check   # same, but only check + fail (what CI runs)
make lint           # luacheck (game/, content/) + clang-tidy (src/)
make lint-lua       # luacheck only
make lint-c         # clang-tidy only
```

- `.clang-format` / `.clang-tidy` govern `src/` (C). 4-space indent, braces
  attached, pointers right-aligned (`char *p`). clang-tidy is scoped to
  `bugprone-*`, `clang-analyzer-*`, `performance-*`, `portability-*` only -
  it's there to catch real bugs, not to bikeshed style.
- `.luacheckrc` / `stylua.toml` govern `game/` and `content/` (Lua). Target
  is Lua 5.4, 2-space indent. `game/tests/*` gets a slightly relaxed
  luacheck profile.
- `.editorconfig` covers whitespace/EOL/charset for every file type in the
  repo (C, Lua, Makefile, YAML, Markdown) - configure your editor to read it.
- These tools aren't required to build; `make`/`make test` never invoke
  them. Run `make format` before committing, `make lint` before opening a
  PR. Both are enforced in CI (see below) and the podman dev image
  (`Containerfile`) ships clang-format/clang-tidy/luacheck/stylua already
  installed.
- `make install-hooks` installs `scripts/pre-commit` as `.git/hooks/pre-commit`,
  which runs `make format-check` and `make lint` before each commit. It's
  opt-in (not installed automatically) since it needs the same tools as
  above; skip a single commit with `git commit --no-verify` if needed.

## CI/CD

GitHub Actions workflows live in `.github/workflows/`:

- `ci.yml` - builds + runs `make test` on Linux, macOS, and Windows
  (native MSYS2 and mingw64 cross-compile from Linux, matching
  `make windows`).
- `lint.yml` - `make format-check`, `make lint-lua` (luacheck), and
  `make lint-c` (clang-tidy).
- `release.yml` - on a `v*` tag push, packages Linux/macOS/Windows builds
  (`make dist` / `make windows`), runs each package on its OS
  (`scripts/smoke-test-dist.sh`) and attaches them to a **draft** GitHub
  release. Run it by hand (workflow_dispatch) for a dry run.

`ci.yml` and `lint.yml` run on every push to `main` and every pull request.
Keep them green; if you add a new engine dependency, update both the
Containerfile and the CI dependency-install steps together.

To release: set `BUYO_VERSION` in `src/engine.h` to the new version (it's
the fallback for builds without git, e.g. source tarballs), then
`git tag -a v1.2.0 -m "Buyo Buyo v1.2.0" && git push origin v1.2.0`. The
version shown in the game comes from the tag (`git describe`). Review the
draft release, write the notes, publish.

## Dev container

`.devcontainer/devcontainer.json` builds the same `Containerfile` used by
`scripts/podman.sh` (Fedora + gcc + SDL2 + Lua 5.4 + clang-format/clang-tidy/
luacheck/stylua). Open the repo in VS Code / any Dev Containers-compatible
IDE and "Reopen in Container" - `make`, `make test`, `make lint`,
`make format` all work out of the box. `build/` and `.cache/` are named
volumes inside the container, so it won't collide with a native host build.
It's for headless dev/CI-like work (no GUI passthrough); use
`scripts/podman.sh run` on the host if you need to actually play.

## Layout

- `src/` - engine in C (SDL2, audio, input, Lua bindings). Comment blocks at
  the top of each file explain its role.
- `game/core/` - engine-agnostic helpers (scene, settings, sound, util).
- `game/puyo/` - simulation: board, rules, match, ai, sequence. Must stay
  deterministic (integer math only, fixed-point positions via `Rules.SUB`) -
  rollback netplay depends on it.
- `game/scenes/` - screens (title, versus, settings).
- `game/view/` - rendering (field, char, sprites, ui, fx, stage, skin).
- `game/net/` - rollback netplay.
- `game/tests/` - Lua self-tests (`--test`), run via `make test`.
- `content/` - data-driven mods: `modes/<name>/mode.lua`,
  `chars/<name>/char.lua`, `stages/<name>/stage.lua`, `skins/<name>/`,
  `music/<name>.lua`. Add new content by copying an existing folder's
  pattern, not by editing the engine.

## Conventions

- SPDX header on every source file: `SPDX-License-Identifier: GPL-2.0-or-later`.
- C: `gnu11`, warnings on (`-Wall -Wextra -Wshadow`) - keep new code warning-free.
  Format with `make format` (clang-format) before committing.
- Lua: 2-space indent, local modules returning a table (`local Foo = {} ... return Foo`).
  Format with `make format` (stylua); keep `make lint-lua` (luacheck) clean.
- Simulation code (`game/puyo/`) must stay deterministic: no floats, no
  wall-clock time, no non-seeded randomness.
