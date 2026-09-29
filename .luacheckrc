-- Luacheck config for the Lua side (game/, content/).
-- Lua 5.4 target; engine C modules are required by name (gfx/audio/input/
-- net/sys), not globals, so no extra read_globals needed for them.
std = "lua54"

self = false
max_line_length = 100

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
}
