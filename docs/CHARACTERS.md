# Characters

A character is a folder `chars/<id>/` with a `char.lua` file. Characters
give a player an identity: a portrait that reacts to the match, a voice,
a theme, and a personality when the CPU plays them. They do **not** change
the rules (that's what [modes](MODES.md) are for), so every character is
fair to play online against anyone.

- Minimal example: [GETTING_STARTED.md](GETTING_STARTED.md#3-your-first-character-with-code-step-by-step)
- Full examples: `content/chars/buyo/char.lua`, `content/chars/blu/char.lua`

## Without code

No `char.lua` needed: a folder with `portrait.png` is a character. Add
mood pictures (`idle.png`, `happy.png`, `worried.png`, `hurt.png`,
`win.png`, `lose.png`), voices (`chain1.ogg`, `chain2.ogg`, ... one per
chain link, and `start`, `attack`, `damage`, `all_clear`, `win`, `lose`
as `.ogg` or `.wav`) and an `info.txt` for the name, color, home stage,
theme and CPU style. Everything below that a file can express works the
same way - see [the no-code guide](GETTING_STARTED.md#2-no-code-needed-just-drop-in-files).

## All fields

Everything is optional except `name`.

```lua
return {
  name = "Professor Blu",            -- shown everywhere
  author = "you",                    -- shown in the select screen and CONTENT
  description = "A patient builder.",-- shown in CONTENT
  order = 10,                        -- select-screen position (lower first; default 100)
  color = { 120, 175, 255 },         -- accent color for the name / UI

  -- the look (pick one, see below)
  portrait = "portrait.png",         -- a single image...
  moods = { happy = "happy.png" },   -- ...optionally one image per mood...
  paint = function(img, w, h, mood) end, -- ...or paint it with code

  -- defaults that go with the character
  skin = "classic",                  -- preferred puyo skin id
  stage = "checkers",                -- home stage id (used when stage = AUTO)
  music = "battle",                  -- theme song id

  -- how the CPU plays this character
  cpu = { chain_goal = 1, speed = 0.9, noise = 0.6 },

  -- sounds for match events
  voice = { chain = { "c1.ogg", "c2.ogg", "c3.ogg" }, win = "win.ogg" },
}
```

## The portrait

The portrait is shown big in the select screen, small in the middle of the
battle screen, and in the results. It is always **fitted into its box and
anchored at the bottom center**; the player-2 side is mirrored
horizontally, so draw your character facing right.

### Option A: images

```lua
portrait = "portrait.png",
```

- PNG (recommended), JPG, BMP or TGA. Transparent background works best.
- Any size; 256x256 to 512x512 is plenty. Square-ish images fill the boxes
  best.
- Add per-mood images to make the character react. Missing moods fall
  back to `portrait`:

```lua
portrait = "idle.png",
moods = {
  happy = "happy.png",     -- chaining
  worried = "sweat.png",   -- the stack is dangerously high
  hurt = "ouch.png",       -- just got hit by nuisance
  win = "victory.png",
  lose = "defeat.png",
},
```

### Option B: paint it with code

```lua
paint = function(img, w, h, mood)
  -- img is a blank 256x256 canvas, mood is one of the six moods
end,
```

`paint` runs once per mood; the result is cached. You draw with shapes:

```lua
local body = gfx.shape():ellipse(w / 2, h * 0.6, 90, 80)
img:fill(body, 90, 20, 36)                                    -- outline
img:fill(body, 255, 118, 132, 255, { inset = 5 })             -- fill, 5px inside
img:fill(body, 255, 180, 190, 255, { inset = 20, soft = 30 }) -- soft highlight
```

Shapes can be combined (`:circle():rect()...` is a union, `"sub"` cuts
holes) and every edge is anti-aliased. The full canvas API is in
[API.md](API.md#canvas-images-and-shapes); `content/chars/buyo/char.lua`
paints a complete character with a bow, eyes and mouths for every mood.

### Moods

| Mood      | When |
|---|---|
| `idle`    | default |
| `happy`   | the player is in the middle of a chain; also when locked in on the select screen |
| `worried` | the column under the X is dangerously high |
| `hurt`    | nuisance just fell on the player (about 1 second) |
| `win`     | won the round / the match |
| `lose`    | lost the round (topped out) |

## Voices

Voices play on top of the normal sound effects. Each entry in `voice` is
either a file, a list of files, or a function:

```lua
voice = {
  start = "ready.ogg",                          -- chosen on the select screen
  chain = { "fire.ogg", "ice.ogg", "thunder.ogg", "finale.ogg" },
  attack = "take-this.ogg",                     -- sent a big attack (30+ nuisance)
  damage = "ouch.ogg",                          -- received 18+ nuisance at once
  all_clear = "wow.ogg",                        -- cleared the whole field
  win = "yay.ogg",
  lose = "nooo.ogg",
}
```

- **`chain` as a list** plays one file per chain link: link 1 plays the
  first file, link 2 the second, and so on; the last file repeats for
  longer chains. Classic puyo characters shout a different spell for
  every link - this is how you do it.
- Files can be **OGG Vorbis or WAV**, any sample rate, mono or stereo.
  Keep them short (under 2 seconds) and normalized.
- Voices are panned to the player's side of the screen automatically.

### Voices made of code

A function receives the chain link number (or 1) and the stereo pan. Use
`synth{}` to make sounds with the built-in synthesizer - no files needed:

```lua
voice = {
  chain = function(n)
    local f = 392 * 2 ^ (math.min(n, 12) * 2 / 12)   -- a step higher every link
    synth { wave = "square", duty = 0.25, freq = f, to = f * 1.5, dur = 0.1, vol = 0.14 }
    synth { wave = "square", duty = 0.25, freq = f * 1.5, dur = 0.16, vol = 0.12, delay = 0.09 }
  end,
},
```

Or mix both: load files yourself and choose one at random:

```lua
local yells = { load_sound("hey1.ogg"), load_sound("hey2.ogg") }
...
voice = {
  attack = function(n, pan) play_sound(yells[math.random(#yells)], 1, pan) end,
},
```

`synth{}` parameters are documented in [API.md](API.md#sound).

## CPU personality

When the CPU plays your character, the difficulty picked in the menu sets
the base skill; `cpu` adjusts the style:

| Field        | Default | Effect |
|---|---|---|
| `chain_goal` | `0`     | how many chain links more (+) or fewer (-) than usual the CPU waits for before firing. `+2` = greedy builder, `-2` = fires small chains constantly |
| `speed`      | `1.0`   | multiplies how fast the CPU thinks and moves. `1.5` = snappy, `0.7` = relaxed |
| `noise`      | `1.0`   | multiplies how often it picks a "good enough" move instead of the best one. `0` = cold precision, `2` = chaotic |

A builder (Blu) and an aggressive rusher behave very differently against a
human even at the same difficulty.

## Recipes

**Pixel-art portrait that stays crisp.** The engine scales portraits
smoothly, which blurs small pixel art. Export your art pre-scaled with
nearest-neighbour from your editor (e.g. 96 px art -> 384 px PNG) and it
stays sharp.

**A character that belongs to a stage.** Set `stage = "your_stage"`; when
players leave STAGE on AUTO, the second player's home stage is used - just
like fighting the character at their place.

**Alternate colors / outfits.** Copy the folder (`hero` -> `hero_alt`) and
change the colors or images. Content files can't `require` each other
(they are sandboxed), but they are small - copying is the intended way.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Character missing from the grid | Check **CONTENT -> ERRORS**. The folder must contain `char.lua` and be named with letters/digits/`_`/`-`. |
| Portrait is a plain colored circle | The image failed to load (see ERRORS) or `paint` raised an error and was disabled. |
| `invalid file name ... (stay inside the item folder)` | File names can't use `..` or absolute paths; put the file in the character folder (sub-folders are fine: `"art/idle.png"`). |
| Voice never plays | Wrong file name (see ERRORS / `--check-content`), or the function errored (it's disabled after the first error; the message is in ERRORS). |
| Online opponent sees a question mark | They don't have your character installed; characters are cosmetic, the match still works. Share the pack! |
