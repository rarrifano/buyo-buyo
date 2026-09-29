# Stages

A stage is the background of the battle screen: a folder `stages/<id>/`
with a `stage.lua`. Stages are purely visual, so they can be as fancy as
you like - they never affect the game or online play.

Examples: `content/stages/checkers/` (images only, no code) and
`content/stages/default/` (all code, no images).

## Anatomy

The screen is **1280 x 720**. A stage is drawn back to front:

1. a vertical **gradient** (or a flat `color`),
2. your **image layers**, in order,
3. your **`draw` function**, if any,
4. then the engine draws the fields, portraits and HUD on top.

The two fields cover x = 104..408 and x = 872..1176 (y = 96..688), so the
most visible parts of your art are the center column and the edges.

```lua
return {
  name = "Sunset Pier",
  author = "you",
  order = 10,
  music = "battle",                  -- song id (see MUSIC.md); optional

  gradient = { top = { 255, 150, 90 }, bottom = { 60, 30, 90 } },
  -- or: color = { 20, 20, 40 },

  layers = {
    { image = "clouds.png", tile = true, scroll_x = 0.2, alpha = 180 },
    { image = "pier.png", y = 360 },
  },

  init = function(state) end,        -- once, when the match starts
  update = function(state, t) end,   -- 60 times per second
  draw = function(state, t) end,     -- every frame, after the layers
}
```

## Image layers

| Field       | Default   | Meaning |
|---|---|---|
| `image`     | required  | file in the stage folder (PNG, JPG, BMP, TGA) |
| `x`, `y`    | `0`       | position of the top-left corner |
| `scroll_x`, `scroll_y` | `0` | movement in pixels per frame (negative = left/up). 0.2 is a slow drift |
| `tile`      | `false`   | repeat the image to fill the whole screen (seamless textures!) |
| `scale`     | `1`       | size multiplier |
| `fit`       | `false`   | stretch the image to exactly 1280x720 (for full-screen paintings) |
| `alpha`     | `255`     | opacity, 0..255 |
| `color`     | white     | tint `{ r, g, b }` multiplied with the image |
| `blend`     | `"alpha"` | `"add"` makes the layer glow (light rays, stars, fog) |
| `filter`    | `"linear"`| `"nearest"` keeps pixel art crisp when scaled |

**Parallax** is just layers with different scroll speeds:

```lua
layers = {
  { image = "far-mountains.png", tile = true, scroll_x = 0.1 },
  { image = "near-hills.png",    tile = true, scroll_x = 0.4, y = 420 },
  { image = "sparkles.png",      tile = true, scroll_y = -0.6, blend = "add", alpha = 120 },
},
```

## Scripted stages

`init`, `update` and `draw` let you animate anything. They receive a
`state` table that belongs to you, and `t`, the frame counter:

```lua
return {
  name = "Starfield",
  gradient = { top = { 5, 5, 20 }, bottom = { 20, 10, 40 } },

  init = function(state)
    state.stars = {}
    for i = 1, 150 do
      state.stars[i] = { x = math.random(0, 1280), y = math.random(0, 720), speed = math.random() * 2 + 0.2 }
    end
  end,

  update = function(state, t)
    for _, s in ipairs(state.stars) do
      s.x = s.x - s.speed
      if s.x < 0 then s.x = 1280 end
    end
  end,

  draw = function(state, t)
    gfx.blend("add")
    for _, s in ipairs(state.stars) do
      gfx.color(200, 220, 255, 60 + s.speed * 60)
      gfx.circle(s.x, s.y, s.speed)
    end
  end,
}
```

- Drawing functions (`gfx.circle`, `gfx.rect`, `gfx.draw` for images...)
  are listed in [API.md](API.md#drawing).
- Load images once, at the top of the file or in `init`:
  `local moon = load_image("moon.png")`, then `gfx.draw(moon, x, y)` in
  `draw`.
- `math.random` is fine here: stages never affect the game.
- The engine resets the color and blend mode after your `draw`, so you
  can't break the HUD.
- If `update` or `draw` raises an error it is disabled and reported in
  **CONTENT -> ERRORS**; the rest of the stage keeps working.

## Performance tips

- Hundreds of `gfx.circle` / `gfx.draw` calls per frame are fine. Tens of
  thousands are not.
- Prefer one big image to many small ones when nothing moves.
- Tiled layers are cheap; huge `fit` images (4K) waste memory - 1280x720
  is the real resolution.

## Menu background

The menus use the stage with id `default`. Put a `stages/default/` in your
mods folder to replace the menu backdrop too.
