-- Battle theme (royal road progression, 150 BPM).
-- A chiptune song for the built-in step sequencer: one token per 16th note
-- ("C5", "F#4", "-" hold, "." rest, "|" bar line). Drums: K S H O C T.
-- Songs can also be audio files: return { name = "...", file = "song.ogg" }.
-- Full reference: docs/MUSIC.md
local function rep(s, n) return (s .. " "):rep(n) end
local function bars(...) return table.concat({ ... }, " | ") end
-- chord helpers: 16-step bass and arpeggio bars
local BASS = {
  F = "F2 . F3 . F2 . F3 . F2 . F3 . F2 . F3 .",
  G = "G2 . G3 . G2 . G3 . G2 . G3 . G2 . G3 .",
  Em = "E2 . E3 . E2 . E3 . E2 . E3 . E2 . E3 .",
  Am = "A2 . A3 . A2 . A3 . A2 . A3 . G2 . G3 .",
  C = "C3 . C4 . C3 . C4 . C3 . C4 . C3 . C4 .",
  Dm = "D2 . D3 . D2 . D3 . D2 . D3 . D2 . D3 .",
}
local ARP = {
  F = rep("F4 A4 C5 A4", 4), G = rep("G4 B4 D5 B4", 4), Em = rep("E4 G4 B4 G4", 4),
  Am = rep("A4 C5 E5 C5", 4), C = rep("C4 E4 G4 E4", 4), Dm = rep("D4 F4 A4 F4", 4),
}
local function progression(tbl, chords)
  local out = {}
  for _, c in ipairs(chords) do out[#out + 1] = tbl[c] end
  return table.concat(out, " | ")
end

local CHORDS = { "F", "G", "Em", "Am", "F", "G", "C", "C",
                 "Dm", "Em", "F", "G", "Dm", "Em", "F", "G" }

return {
  name = "Battle",
  author = "Buyo Buyo",
  bpm = 150, spb = 4, loop = true,
  channels = {
    { -- lead
      wave = "square", duty = 0.25, vol = 0.16, legato = 0.92, attack = 0.004, release = 0.05,
      vib = 0.12, vibrate = 6, pan = 0.1,
      notes = bars(
        "C5 - A4 - C5 - D5 - C5 - - - A4 - G4 -",
        "B4 - - - D5 - - - G5 - F5 - D5 - B4 -",
        "G4 - B4 - E5 - - - D5 - B4 - G4 - B4 -",
        "C5 - - - B4 - - - A4 - - - - - . .",
        "A4 - C5 - F5 - - - E5 - D5 - C5 - A4 -",
        "B4 - D5 - G5 - - - A5 - G5 - F5 - D5 -",
        "E5 - - - G5 - - - C6 - - - B5 - G5 -",
        "C6 - - - - - - - . . . . B4 - C5 -",
        "D5 - F5 - A5 - - - G5 - F5 - E5 - D5 -",
        "E5 - G5 - B5 - - - A5 - G5 - F5 - E5 -",
        "F5 - E5 - F5 - A5 - C6 - - - A5 - F5 -",
        "G5 - - - F5 - - - E5 - - - D5 - - -",
        "D5 - F5 - A5 - - - G5 - F5 - E5 - D5 -",
        "E5 - G5 - B5 - - - C6 - B5 - A5 - G5 -",
        "A5 - - - G5 - - - F5 - - - E5 - - -",
        "D5 - - - - - - - G5 - F5 - E5 - D5 -"),
    },
    { -- bass
      wave = "triangle", vol = 0.42, legato = 0.7, release = 0.03,
      notes = progression(BASS, CHORDS),
    },
    { -- bubbly arpeggio
      wave = "square", duty = 0.125, vol = 0.05, legato = 0.5, release = 0.02, pan = -0.25,
      notes = progression(ARP, CHORDS),
    },
    { -- drums
      drums = true, vol = 0.8,
      notes = rep("K . H . S . H . K . H K S . H .", 15) .. " K . H . S . H . K S K S S S S S",
    },
  },
}
