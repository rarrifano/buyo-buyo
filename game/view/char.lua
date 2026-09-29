-- Character runtime: portraits (images or painted by code) and voices.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Moods: idle, happy (chaining), worried (danger), hurt (took nuisance),
--        win, lose.
-- Portrait priority: moods[mood] image -> portrait image -> paint(img, w, h, mood).
-- Voice events: start, chain (n = link), attack, damage, all_clear, win, lose.
-- A voice entry can be a file name, a list of file names (chain: one per
-- link), or a function(n) that plays sounds itself (e.g. synth{...}).
local Content = require "core.content"

local Char = {}

Char.MOODS = { "idle", "happy", "worried", "hurt", "win", "lose" }
Char.PAINT_SIZE = 256

local textures = {}
local sounds = {}

local function load_tex(def, file)
  local key = def.id .. "|" .. file
  if textures[key] ~= nil then return textures[key] or nil end
  local p, err = Content.path(def, file)
  local tex
  if p then
    tex, err = gfx.load(p)
  end
  if not tex then Content.report("chars", def.id, tostring(err)) end
  textures[key] = tex or false
  return tex
end

function Char.texture(def, mood)
  if not def then return nil end
  mood = mood or "idle"
  if type(def.moods) == "table" and type(def.moods[mood]) == "string" then
    local t = load_tex(def, def.moods[mood])
    if t then return t end
  end
  if type(def.portrait) == "string" then
    local t = load_tex(def, def.portrait)
    if t then return t end
  end
  if type(def.paint) == "function" then
    local key = def.id .. "|paint|" .. mood
    if textures[key] == nil then
      local img = gfx.image(Char.PAINT_SIZE, Char.PAINT_SIZE)
      Content.call(def, "paint", img, Char.PAINT_SIZE, Char.PAINT_SIZE, mood)
      local failed = def._disabled and def._disabled.paint
      textures[key] = not failed and img:texture() or false
    end
    return textures[key] or nil
  end
  return nil
end

-- draw the portrait fitted in the box (x, y, w, h), bottom-centred
function Char.draw(def, x, y, w, h, mood, t, flip, alpha)
  local tex = Char.texture(def, mood)
  gfx.color(255, 255, 255, alpha or 255)
  if tex then
    local tw, th = tex:size()
    local k = math.min(w / tw, h / th)
    local bob = (mood == "happy" or mood == "win")
        and math.abs(math.sin((t or 0) * 0.25)) * h * 0.04
      or 0
    gfx.draw(tex, x + w / 2, y + h - bob, 0, flip and -k or k, k, tw / 2, th)
  else
    local c = def and def.color or { 200, 200, 200 }
    gfx.color(c[1], c[2], c[3], alpha or 255)
    gfx.circle(x + w / 2, y + h / 2, math.min(w, h) * 0.4)
  end
end

local function sound(def, file)
  local key = def.id .. "|" .. file
  if sounds[key] ~= nil then return sounds[key] or nil end
  local p, err = Content.path(def, file)
  local s
  if p then
    s, err = audio.load(p)
  end
  if not s then Content.report("chars", def.id, tostring(err)) end
  sounds[key] = s or false
  return s
end

-- returns true if the character produced a sound for this event
function Char.voice(def, event, n, pan)
  if not def or type(def.voice) ~= "table" then return false end
  local v = def.voice[event]
  if type(v) == "function" then
    def._voice_off = def._voice_off or {}
    if def._voice_off[event] then return false end
    local ok, err = pcall(v, n, pan)
    if not ok then
      def._voice_off[event] = true
      Content.report(
        "chars",
        def.id,
        "voice." .. event .. " failed and was disabled: " .. tostring(err)
      )
      return false
    end
    return true
  end
  if type(v) == "table" then v = v[math.min(math.max(n or 1, 1), #v)] end
  if type(v) == "string" then
    local s = sound(def, v)
    if s then
      audio.play_sample(s, 1, (pan or 0) * 0.6)
      return true
    end
  end
  return false
end

function Char.clear_cache()
  textures = {}
  sounds = {}
end

return Char
