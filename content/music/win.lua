-- Victory jingle (does not loop).
-- A chiptune song for the built-in step sequencer: one token per 16th note
-- ("C5", "F#4", "-" hold, "." rest, "|" bar line). Drums: K S H O C T.
-- Songs can also be audio files: return { name = "...", file = "song.ogg" }.
-- Full reference: docs/MUSIC.md
local function rep(s, n) return (s .. " "):rep(n) end
local function bars(...) return table.concat({ ... }, " | ") end

return {
  name = "Victory",
  author = "Buyo Buyo",
  bpm = 160, spb = 4, loop = false,
  channels = {
    { wave = "square", duty = 0.25, vol = 0.18, legato = 0.9, release = 0.1,
      notes = "C5 E5 G5 C6 - - G5 - C6 - - - - - - - . . . ." },
    { wave = "triangle", vol = 0.4, legato = 0.9,
      notes = "C3 - - - - - G2 - C3 - - - - - - -" },
    { drums = true, vol = 0.7, notes = "K . . . K . S . C . . . . . . ." },
  },
}
