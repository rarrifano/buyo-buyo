# Getting started

This guide takes you from zero to a working, shareable content pack.

## 1. Find your mods folder

The game creates it on first start. It lives in your user data directory:

| System  | Mods folder |
|---|---|
| Linux   | `~/.local/share/buyo-buyo/buyo-buyo/mods/` |
| Windows | `%APPDATA%\buyo-buyo\buyo-buyo\mods\` |
| macOS   | `~/Library/Application Support/buyo-buyo/buyo-buyo/mods/` |

Quickest way: in the game open **CONTENT**, press **Z**, choose
**OPEN MODS FOLDER** (the path is also copied to your clipboard).

Inside you'll find one sub-folder per kind of content:

```
mods/
  chars/     one folder per character   -> chars/<id>/char.lua
  stages/    one folder per stage       -> stages/<id>/stage.lua
  skins/     one folder per puyo skin   -> skins/<id>/skin.lua
  modes/     one folder per game mode   -> modes/<id>/mode.lua
  music/     one folder per song        -> music/<id>/song.lua  (or music/<id>.lua)
```

You can also keep content anywhere else and point the game at it:

```
buyo-buyo -- --mods ~/my-buyo-pack --mods ~/friends-pack
```

Load order: built-in `content/` first, then your mods folder, then every
`--mods` folder. A later item with the same id replaces an earlier one.

## 2. No code needed: just drop in files

You can make every kind of content **without writing any code**. Make a
folder, put your pictures and sounds in it with the names below, press
**F5**. That's all.

| To make a... | Folder | Put in it |
|---|---|---|
| character | `chars/My Hero/` | `portrait.png` - and if you like, one picture per mood: `happy.png`, `worried.png`, `hurt.png`, `win.png`, `lose.png` - and voices: `chain1.ogg`, `chain2.ogg`, ... `win.ogg`, `lose.ogg` |
| stage | `stages/Beach/` | `background.png` (stretched to fill the screen); pictures with `tile` in the name repeat and drift (`clouds_tile.png`); any other picture is laid on top; `music.ogg` plays during the match |
| puyo skin | `skins/Pixel Blobs/` | `puyos.png` - a sheet of 16 x 7 puyos (get a template with **EXPORT SKIN SHEET**, see [SKINS.md](SKINS.md)) |
| song | `music/` | any `.ogg` or `.wav` file, e.g. `music/My Song.ogg` |
| game mode | `modes/Fast Five/` | an `info.txt` with the rules to change (see below) |

Pictures can be PNG (best), JPG, BMP or TGA; sounds OGG or WAV. Folder and
file names may contain spaces. If a folder holds only **one** picture, it
is used as the portrait / background / sheet whatever its name.

### info.txt: names, colors and settings in plain text

Every folder can also have an `info.txt` - a plain text file, one setting
per line:

```
name = Tomato Queen
author = your name
description = Ruler of the vegetable garden.
color = #ff5a46
```

Colors can be written `#ff5a46` or `255, 90, 70`. Lines starting with `#`
are comments. Without an `info.txt` the name comes from the folder name
(`tomato_queen` becomes "Tomato Queen").

Settings each kind understands:

| Kind | Settings |
|---|---|
| all | `name`, `author`, `description`, `order` (position in lists, lower first) |
| character | `color`, `skin`, `stage`, `music` (ids of other content), `cpu_chain_goal`, `cpu_speed`, `cpu_noise` (see [CHARACTERS.md](CHARACTERS.md#cpu-personality)) |
| stage | `color` or `top_color` + `bottom_color` (background gradient behind your pictures), `scroll_x`, `scroll_y` (speed of `tile` pictures), `tile_alpha`, `music` (a song id, if there is no music file) |
| skin | `cell` (cell size, normally detected), `filter` (`nearest` for crisp pixel art - automatic for small cells), `faces` (`no` if your puyos have their faces drawn in), `color1` ... `color6` |
| song | `loop` (`yes`/`no`), `loop_start` (seconds), `volume` (0 to 1) |
| mode | any rule from [the rules table](MODES.md#all-rules), e.g. `colors = 5`, `gravity = 80`, `target_points = 50`, `first_to = 3` |

A complete no-code character is simply:

```
chars/
  Tomato Queen/
    portrait.png
    happy.png
    chain1.ogg
    chain2.ogg
    info.txt        name = Tomato Queen / color = #ff5a46
```

When you want more - pictures painted by code, animated stages, rules that
react to what happens in the match - switch to a Lua file, below. You can
mix: a `char.lua` can still use your PNG and OGG files.

## 3. Your first character with code, step by step

Create `mods/chars/tomato/char.lua`:

```lua
return {
  name = "Tomato",
  author = "you",
  description = "Round, red and ready to rumble.",
  color = { 255, 90, 70 },

  paint = function(img, w, h, mood)
    local body = gfx.shape():circle(w / 2, h * 0.58, w * 0.36)
    img:fill(body, 120, 20, 10)                       -- dark outline
    img:fill(body, 255, 90, 70, 255, { inset = 5 })   -- red body
    -- two eyes that close when happy
    for side = -1, 1, 2 do
      local ex, ey = w / 2 + side * 34, h * 0.52
      if mood == "happy" or mood == "win" then
        img:fill(gfx.shape():capsule(ex - 12, ey, ex + 12, ey, 4), 40, 10, 10)
      else
        img:fill(gfx.shape():circle(ex, ey, 10), 40, 10, 10)
      end
    end
    -- a leaf on top
    img:fill(gfx.shape():ellipse(w / 2 + 14, h * 0.2, 26, 10, -0.4), 60, 170, 70)
  end,
}
```

Start the game (or press **F5** if it's running) and pick **VS CPU**:
Tomato is in the grid. That's it - everything else in
[CHARACTERS.md](CHARACTERS.md) is optional polish.

Prefer drawing in an image editor? Replace `paint` with
`portrait = "tomato.png"` and put `tomato.png` (any size, transparent
background) next to `char.lua`.

## 4. The edit -> test loop

- **F5** reloads the engine *and* all content without restarting.
- **CONTENT** (main menu) shows every installed item with a live preview:
  character portraits in every mood, skins with connected puyos, mode
  rules and hooks, songs you can play.
- **CONTENT -> ERRORS** lists everything that failed to load, with the file
  and line number.
- `print(...)` in your content goes to the terminal, prefixed with the item
  id, e.g. `[chars/tomato] hello`.
- Validate everything from the command line (great before sharing):

  ```
  buyo-buyo --headless -- --check-content
  ```

  It loads every item for real (images, sounds, skins, portraits in every
  mood), plays a quick CPU match with every mode to smoke-test its hooks,
  and exits with code 1 if anything is wrong.

- Jump straight into a match with your stuff:

  ```
  buyo-buyo -- --mode cpu --char1 tomato --stage my_stage --game-mode my_mode
  ```

## 5. Start from something that works

In **CONTENT**, select any item, press **Z** -> **REMIX INTO MY MODS**. The
whole folder is copied to your mods folder as `my_<id>` (with "My" added to
its name) and reloaded, ready to edit. This is the fastest way to learn:
change one thing, press F5, see what happened.

For skins there's also **EXPORT SKIN SHEET**: it writes the selected skin
as a PNG template you can paint over (see [SKINS.md](SKINS.md)).

## 6. Share your pack

A pack is just folders. Zip them with the same layout as the mods folder:

```
tomato-pack.zip
  chars/tomato/char.lua
  chars/tomato/voice-chain1.ogg
  stages/tomato_farm/stage.lua
  stages/tomato_farm/field.png
  README.txt        <- say what's inside, credits, license
```

Players unzip it into their mods folder (or keep it anywhere and use
`--mods`). Tips:

- Keep ids unique and descriptive (`tomato_farm`, not `stage1`) so packs
  don't overwrite each other.
- Characters, stages, skins and music are **cosmetic**: online opponents
  don't need your pack (they'll see a stand-in for a character they don't
  have). **Modes** change the rules, so both players need the *identical*
  mode file to play it online - see [NETPLAY.md](NETPLAY.md).
- Only ship files you're allowed to share. Credit sources.

## 7. What content can and cannot do

Content files run in a **sandbox**: they get drawing, sound and math
functions ([API.md](API.md)), and can read files from their own folder only.
They can't touch other files, the network, or run programs. That's what
makes it safe to try packs from strangers.

Next: pick a guide from the [handbook index](README.md).
