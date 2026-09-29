# Content API reference

Everything a content file (`char.lua`, `stage.lua`, `skin.lua`, `mode.lua`,
`song.lua`) can use. Content runs in a sandbox: only what is listed here
exists.

## Always available

| Name | |
|---|---|
| Lua basics | `assert error ipairs next pairs pcall xpcall select tonumber tostring type setmetatable getmetatable rawequal rawlen` |
| Libraries | `math string table utf8 coroutine` (copies; in **modes** `math.random`/`math.randomseed` are removed) |
| `print(...)` | prints to the terminal, prefixed with `[kind/id]` |
| `ENGINE` | `{ version = "0.2.0", api = 1, platform = "Linux" }` |
| `PALETTE` | the six default colors: `PALETTE[1]` red ... `PALETTE[5]` purple, `PALETTE[6]` nuisance, each `{ r, g, b }` |
| `RULES` | a copy of the default rules (see [MODES.md](MODES.md#all-rules)) |
| `SUB` | 1024: sub-rows per row (falling positions) |
| `asset(name)` | full path of a file in the item's folder (errors if the name tries to leave it) |

Not available: `io`, `os`, `require`, `load`, `dofile`, the network, or
any file outside the item's own folder.

## Drawing

Available to characters, stages and skins (and passed to a mode's `hud`).
The screen is 1280 x 720; colors are 0..255.

| Function | |
|---|---|
| `gfx.color(r, g, b [, a])` | color (and opacity) for everything drawn next; images are tinted by it |
| `gfx.blend(mode)` | `"alpha"` (normal), `"add"` (glow), `"mul"` (darken), `"none"` |
| `gfx.rect(x, y, w, h)` | filled rectangle |
| `gfx.rect_line(x, y, w, h [, thickness])` | rectangle outline |
| `gfx.line(x1, y1, x2, y2)` | 1-pixel line |
| `gfx.circle(x, y, radius)` | filled, anti-aliased circle |
| `gfx.draw(tex, x, y [, angle, sx, sy, ox, oy])` | draw an image. `angle` in radians, `sx`/`sy` scale (negative = mirror), `ox`/`oy` the point of the image placed at `x, y` (and rotated around) |
| `gfx.drawq(tex, qx, qy, qw, qh, x, y [, angle, sx, sy, ox, oy])` | draw only the `qx, qy, qw, qh` part of an image (sprite sheets, animation frames) |
| `gfx.stretch(tex, x, y, w, h)` | draw an image stretched to a rectangle |
| `gfx.text(str, x, y [, scale [, align]])` | 8x8 pixel font; `scale` 1..n, `align` `"left"`, `"center"`, `"right"`; `\n` for new lines |
| `gfx.text_width(str [, scale])` | width in pixels |
| `gfx.size()` | `1280, 720` |

Special font characters: `"\001"` left arrow, `"\002"` right, `"\003"` up,
`"\004"` down, `"\005"` star, `"\006"` heart, `"\007"` dot.

**Images (textures)**

| | |
|---|---|
| `load_image(name [, filter])` | load a PNG/JPG/BMP/TGA from the item folder (cached). `filter` `"nearest"` for pixel art |
| `tex:size()` | width, height |
| `tex:filter("nearest" \| "linear")` | change scaling filter |

Animation from a sprite sheet (8 frames of 64 x 64 in a row):

```lua
local sheet = load_image("run.png", "nearest")
...
local frame = (t // 6) % 8
gfx.drawq(sheet, frame * 64, 0, 64, 64, x, y, 0, 2, 2)  -- drawn at 2x
```

## Canvas: images and shapes

A canvas is an image in memory you paint with anti-aliased shapes, then
turn into a texture. Characters' `paint` and skins' `paint` receive one;
you can also make your own anywhere.

| Function | |
|---|---|
| `gfx.image(w, h)` | new transparent canvas |
| `load_canvas(name)` | load an image file from the item folder as a canvas |
| `img:fill(shape, r, g, b [, a [, opts]])` | paint a shape |
| `img:gradient(r1, g1, b1, a1, r2, g2, b2, a2)` | fill the whole canvas with a vertical gradient |
| `img:pixel(x, y, r, g, b [, a])` | set one pixel (0-based) |
| `img:blit(other, x, y)` | paste another canvas (alpha-blended) |
| `img:crop(x, y, w, h)` | new canvas from a region |
| `img:size()` | width, height |
| `img:texture([filter])` | turn it into a texture you can `gfx.draw` |

`opts` for `fill`:

| Option | Default | |
|---|---|---|
| `inset` | 0 | shrink the shape by this many pixels (negative grows it: outlines!) |
| `soft` | 1 | edge softness in pixels; 10+ gives glows and smooth shading |
| `dx`, `dy` | 0 | offset the shape (shading, drop shadows) |
| `mode` | `"over"` | `"over"` paints, `"erase"` cuts transparent holes, `"add"` lightens |

**Shapes** are built by chaining primitives; by default they are joined
(union). Add `"sub"` as the last argument to cut a primitive away, or
`"and"` to keep only the overlap.

| Primitive | |
|---|---|
| `gfx.shape()` | empty shape |
| `sh:circle(cx, cy, r [, op])` | |
| `sh:ellipse(cx, cy, rx, ry [, angle [, op]])` | `angle` in radians |
| `sh:rect(x, y, w, h [, radius [, op]])` | `radius` rounds the corners |
| `sh:capsule(x1, y1, x2, y2, r [, op])` | a thick line with round ends |
| `sh:poly({ x1, y1, x2, y2, ... } [, op])` | any polygon (stars, crowns, hats) |

```lua
-- a crescent moon with an outline and a soft glow
local moon = gfx.shape():circle(64, 64, 40):circle(84, 50, 34, "sub")
img:fill(moon, 255, 230, 120, 120, { inset = -8, soft = 16 })  -- glow
img:fill(moon, 90, 60, 10)                                      -- outline
img:fill(moon, 255, 230, 120, 255, { inset = 3 })               -- body
```

The trick used by all built-in art: fill the same shape several times
with growing `inset` and lighter colors (and a little `dx`/`dy` towards
the light) to get outlines and shading for free.

## Sound

Available to characters, stages and skins.

| Function | |
|---|---|
| `load_sound(name)` | load an OGG or WAV from the item folder |
| `play_sound(sound [, vol [, pan [, pitch]]])` | play it: `vol` 0..1, `pan` -1..1, `pitch` 1 = normal, 2 = an octave up |
| `sound:duration()` | length in seconds |
| `synth{ ... }` | play a synthesized sound effect, parameters below |

`synth` parameters (all optional):

| Parameter | Default | |
|---|---|---|
| `wave` | `"square"` | `"square"`, `"triangle"`, `"saw"`, `"sine"`, `"noise"` |
| `freq` | 440 | start frequency in Hz |
| `to` | = `freq` | end frequency (slides smoothly: zaps, drops, rises) |
| `dur` | 0.1 | seconds |
| `vol` | 0.5 | 0..1 |
| `pan` | 0 | -1 left .. 1 right |
| `attack`, `release` | 0.002, 0.02 | fade in / out, seconds |
| `decay` | 0 | exponential fade (percussive sounds: 10..40) |
| `duty` | 0.5 | square wave width |
| `delay` | 0 | start later, in seconds (arpeggios!) |
| `vib`, `vibrate` | 0, 6 | vibrato depth (semitones) and speed (Hz) |

```lua
synth { wave = "noise", freq = 2000, to = 200, dur = 0.3, decay = 12, vol = 0.3 }      -- explosion
synth { wave = "sine", freq = 880, to = 1760, dur = 0.15, vol = 0.3 }                  -- bling
for i, n in ipairs { 0, 4, 7, 12 } do                                                   -- fanfare
  synth { wave = "square", duty = 0.25, freq = 523 * 2 ^ (n / 12), dur = 0.12, delay = i * 0.08 }
end
```

## Modes

Modes don't get drawing or sound (they are simulation); their hooks
receive the match and players instead - see [MODES.md](MODES.md#what-hooks-can-use).
Their `hud` hook receives the drawing table as an argument.

## Versioning

`ENGINE.api` is the content API version (currently 1). It only changes
when something content relies on changes incompatibly; you can check it
to support several engine versions:

```lua
if ENGINE.api > 1 then print("made for API 1, may need updating") end
```
