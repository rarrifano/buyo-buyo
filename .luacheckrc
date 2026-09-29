-- Luacheck config for the Lua side (game/, content/).
-- Lua 5.4 target; the engine injects gfx/audio/input/net/sys as globals
-- (see src/*.c bindings), so they're declared as read_globals below.
std = "lua54"

self = false
max_line_length = 100

read_globals = {
  "gfx",
  "audio",
  "input",
  "net",
  "sys",
}

-- Style choices we deliberately don't want flagged:
ignore = {
  "212/self",   -- unused "self" in methods (some modules take it for OO calls)
  "631",        -- line too long handled loosely by max_line_length above
}

exclude_files = {
  "third_party/*",
  "build*/*",
}

files["game/tests/*"] = {
  std = "lua54+busted",
  -- standalone test runs (plain `lua game/tests/foo.lua`) stub out the
  -- engine's sys global themselves
  globals = { "sys" },
}

-- content/*.lua descriptors run inside Content's sandbox (see
-- game/core/content.lua make_env), not the engine's top-level globals:
-- no gfx/audio/input/net/sys, just these helpers plus math/string/table/etc.
files["content/**/*.lua"] = {
  read_globals = {
    "gfx",
    "synth",
    "play_sound",
    "load_image",
    "load_canvas",
    "load_sound",
    "asset",
    "PALETTE",
    "RULES",
    "SUB",
    "ENGINE",
  },
}
