-- Defeat jingle (does not loop).
-- A chiptune song for the built-in step sequencer: one token per 16th note
-- ("C5", "F#4", "-" hold, "." rest, "|" bar line). Drums: K S H O C T.
-- Songs can also be audio files: return { name = "...", file = "song.ogg" }.
-- Full reference: docs/MUSIC.md

return {
  name = "Defeat",
  author = "Buyo Buyo",
  bpm = 96,
  spb = 4,
  loop = false,
  channels = {
    {
      wave = "square",
      duty = 0.5,
      vol = 0.14,
      legato = 0.95,
      vib = 0.4,
      vibrate = 7,
      release = 0.1,
      notes = "G4 - - F#4 - - F4 - - E4 - - - - - - . .",
    },
    { wave = "triangle", vol = 0.4, legato = 0.9, notes = "C3 - - B2 - - A#2 - - A2 - - - - - -" },
  },
}
