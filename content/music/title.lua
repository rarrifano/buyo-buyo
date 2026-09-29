-- Title theme: a gentle music-box loop.
-- A chiptune song for the built-in step sequencer: one token per 16th note
-- ("C5", "F#4", "-" hold, "." rest, "|" bar line). Drums: K S H O C T.
-- Songs can also be audio files: return { name = "...", file = "song.ogg" }.
-- Full reference: docs/MUSIC.md
local function rep(s, n) return (s .. " "):rep(n) end
local function bars(...) return table.concat({ ... }, " | ") end

return {
  name = "Title",
  author = "Buyo Buyo",
  bpm = 112,
  spb = 4,
  loop = true,
  channels = {
    { -- melody (music-box triangle)
      wave = "triangle",
      vol = 0.34,
      legato = 0.9,
      attack = 0.004,
      release = 0.08,
      vib = 0.1,
      vibrate = 5,
      notes = bars(
        "E5 - G5 - E5 - C5 - D5 - E5 - - - . .",
        "C5 - E5 - A5 - - - G5 - E5 - - - . .",
        "F5 - E5 - D5 - C5 - A4 - C5 - - - . .",
        "B4 - C5 - D5 - - - - - - - . . . .",
        "E5 - G5 - E5 - C5 - D5 - E5 - - - G5 -",
        "A5 - - - G5 - E5 - C5 - - - D5 - E5 -",
        "F5 - - - E5 - D5 - B4 - - - D5 - - -",
        "C5 - - - - - - - . . . . . . . ."
      ),
    },
    { -- soft square echo of the melody, an octave down
      wave = "square",
      duty = 0.25,
      vol = 0.05,
      legato = 0.6,
      transpose = -12,
      pan = 0.3,
      notes = bars(
        "E5 - G5 - E5 - C5 - D5 - E5 - - - . .",
        "C5 - E5 - A5 - - - G5 - E5 - - - . .",
        "F5 - E5 - D5 - C5 - A4 - C5 - - - . .",
        "B4 - C5 - D5 - - - - - - - . . . .",
        "E5 - G5 - E5 - C5 - D5 - E5 - - - G5 -",
        "A5 - - - G5 - E5 - C5 - - - D5 - E5 -",
        "F5 - - - E5 - D5 - B4 - - - D5 - - -",
        "C5 - - - - - - - . . . . . . . ."
      ),
    },
    { -- bass
      wave = "triangle",
      vol = 0.40,
      legato = 0.85,
      notes = bars(
        "C3 - - - G2 - - - C3 - - - G2 - - -",
        "A2 - - - E2 - - - A2 - - - E2 - - -",
        "F2 - - - C3 - - - F2 - - - C3 - - -",
        "G2 - - - D3 - - - G2 - - - D3 - - -",
        "C3 - - - G2 - - - C3 - - - G2 - - -",
        "A2 - - - E2 - - - A2 - - - E2 - - -",
        "D3 - - - A2 - - - G2 - - - D3 - - -",
        "C3 - - - G2 - - - C3 - - - - - - -"
      ),
    },
    { -- light percussion
      drums = true,
      vol = 0.45,
      notes = rep("K . . . H . . . S . . . H . . H", 8),
    },
  },
}
