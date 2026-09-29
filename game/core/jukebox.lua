-- Music player for content/music songs (chiptune tables or audio files).
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- The engine asks for songs by id; the conventional ids are
--   title, select, battle, win, lose
-- and stages / characters can name their own. Missing ids are silent.
local Content = require "core.content"

local Jukebox = { current = nil }

function Jukebox.play(id, fallback)
  local def = Content.get("music", id) or Content.get("music", fallback)
  local key = def and def.id or nil
  if Jukebox.current == key and key ~= nil then return end
  Jukebox.current = key
  if not def then
    audio.stop_music()
    return
  end
  if def.file then
    local p, err = Content.path(def, def.file)
    local ok
    if p then
      ok, err = audio.music_file(p, {
        loop = def.loop ~= false,
        loop_start = tonumber(def.loop_start) or 0,
        volume = tonumber(def.volume) or 1,
      })
    end
    if not ok then Content.report("music", def.id, tostring(err)) end
  else
    audio.music(def)
  end
end

function Jukebox.stop()
  Jukebox.current = nil
  audio.stop_music()
end

return Jukebox
