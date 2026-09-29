-- Persistent settings, stored as a Lua table in the user's data directory.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Settings = {}

local DEFAULTS = {
  first_to = 2, -- rounds needed to win a match
  colors = 4, -- 3..5 colors (modes may override)
  cpu_level = 2,
  hard_drop = true, -- Up = hard drop (otherwise Up rotates)
  ghost = true, -- landing preview
  music = 6, -- 0..10
  sfx = 8, -- 0..10
  fullscreen = false,
  skin = "character", -- "character" = each character's preferred skin, or a skin id
  mode = "tsu", -- last mode picked
  char1 = "buyo", -- last characters picked
  char2 = "blu",
  net_delay = 2, -- online input delay in frames
  net_port = 7777, -- UDP port for online play
  name = "PLAYER",
}

Settings.data = {}
for k, v in pairs(DEFAULTS) do
  Settings.data[k] = v
end

function Settings.load()
  local src = sys.load "settings.lua"
  if not src then return end
  local chunk = load(src, "settings", "t", {})
  if not chunk then return end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then return end
  for k, def in pairs(DEFAULTS) do
    if type(t[k]) == type(def) then Settings.data[k] = t[k] end
  end
end

function Settings.save()
  local keys = {}
  for k in pairs(Settings.data) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local out = { "return {" }
  for _, k in ipairs(keys) do
    local v = Settings.data[k]
    out[#out + 1] =
      string.format("  %s = %s,", k, type(v) == "string" and string.format("%q", v) or tostring(v))
  end
  out[#out + 1] = "}\n"
  sys.save("settings.lua", table.concat(out, "\n"))
end

function Settings.apply()
  local d = Settings.data
  audio.volume(0.9, d.sfx / 10, d.music / 10)
  if sys.fullscreen() ~= d.fullscreen then sys.fullscreen(d.fullscreen) end
end

return Settings
