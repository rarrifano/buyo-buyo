# Music

Songs live in `music/`. A song is either **a chiptune written as text**
(played by the built-in synthesizer, tiny files, loops perfectly) or **an
audio file** (OGG Vorbis or WAV). Either way it is one Lua file:

- `music/<id>.lua`, or
- `music/<id>/song.lua` (use a folder when the song has an audio file).

## Without code

Drop an `.ogg` or `.wav` file into `music/` and it's a song, named after
the file (`music/Boss Theme.ogg` -> id `Boss_Theme`). For loop points and
volume, use a folder with the file and an `info.txt`
(`loop_start = 12.5`, `volume = 0.8`). A `music.ogg` inside a stage
folder plays on that stage. See [the no-code guide](GETTING_STARTED.md#2-no-code-needed-just-drop-in-files).

## Where songs are used

The engine asks for songs by id:

| Id | Plays |
|---|---|
| `title`  | title screen and menus |
| `select` | character select (falls back to `title`) |
| `battle` | matches, unless the stage or the match screen picks another |
| `win`    | after winning a round (doesn't need to loop) |
| `lose`   | after losing a round against the CPU |

Stages (`music = "my_song"`) and characters (`music = "my_theme"`) can
name any song id, and players can force a song on the match screen
(MUSIC). To replace a built-in song, put a song with the same id in your
mods folder.

## Audio files

`music/sunset/song.lua` next to `music/sunset/sunset.ogg`:

```lua
return {
  name = "Sunset Drive",
  author = "you",
  file = "sunset.ogg",   -- OGG Vorbis (recommended) or WAV
  loop = true,           -- default true
  loop_start = 12.5,     -- seconds: after the end, jump back here (skips the intro)
  volume = 0.8,          -- 0..1, relative to the player's music volume
}
```

- OGG files are streamed (small memory use); WAV files are decoded fully,
  so keep WAVs short.
- Any sample rate works; 44.1 or 48 kHz stereo is ideal.
- For a seamless loop, cut the file exactly at the loop end and set
  `loop_start` to the time the loop begins.

## Chiptunes

```lua
return {
  name = "Tiny Tune",
  author = "you",
  bpm = 140,         -- beats per minute
  spb = 4,           -- steps per beat (4 = every token is a 16th note)
  loop = true,
  channels = {
    { wave = "square", duty = 0.25, vol = 0.16,
      notes = "C5 - E5 - G5 - E5 - | D5 - F5 - A5 - F5 -" },
    { wave = "triangle", vol = 0.4,
      notes = "C3 . C3 . G2 . G2 . | D3 . D3 . A2 . A2 ." },
    { drums = true, vol = 0.8,
      notes = "K . H . S . H . | K . H K S . H ." },
  },
}
```

### Notes

Each token is one step (a 16th note with `spb = 4`), separated by spaces:

| Token | Meaning |
|---|---|
| `C4`, `F#5`, `Bb3` | a note: letter, optional `#` or `b`, octave 0..9 (`A4` = 440 Hz) |
| `-` | hold the previous note one more step |
| `.` | rest (silence) |
| `\|` | bar line, ignored (just for readability) |

Channels loop independently, so a 16-step drum loop under a 128-step
melody is fine. Up to 8 channels.

### Drum tokens (`drums = true`)

| Token | Sound |
|---|---|
| `K` | kick |
| `S` | snare |
| `H` | closed hi-hat |
| `O` | open hi-hat |
| `C` | crash |
| `T` | tom |

### Channel options

| Option | Default | Meaning |
|---|---|---|
| `wave` | `"square"` | `"square"`, `"triangle"`, `"saw"`, `"sine"`, `"noise"` |
| `vol` | 0.3 | loudness 0..1 (keep the sum of channels around 1) |
| `pan` | 0 | -1 left .. 1 right |
| `duty` | 0.5 | square wave width: 0.5 hollow, 0.25 nasal, 0.125 thin |
| `attack` | 0.005 | seconds to fade in each note |
| `release` | 0.03 | seconds to fade out at the end of each note |
| `decay` | 0 | exponential fade while the note plays (pluck/bell: 6..20) |
| `legato` | 0.9 | fraction of the note length actually played (0.5 = staccato) |
| `transpose` | 0 | semitones up/down (12 = an octave) |
| `vib`, `vibrate` | 0, 5.5 | vibrato depth (semitones) and speed (Hz) |

### Tips

- Helper functions keep long songs readable. The built-in
  `content/music/battle.lua` builds its bass line and arpeggios from chord
  names with a tiny `progression()` function - copy it.
- Square + triangle bass + drums is the classic 8-bit recipe.
- Preview songs in **CONTENT -> MUSIC** (select a song, press **Z**).
- Make a jingle (`win`, `lose`) with `loop = false`.

## Sound effects

Characters' voices and custom sounds are covered in
[CHARACTERS.md](CHARACTERS.md#voices). The `synth{}` function used there
takes the same wave names as channels, see [API.md](API.md#sound).
