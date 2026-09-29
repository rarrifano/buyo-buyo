# Skins

A skin changes how the puyos look: a folder `skins/<id>/` with a
`skin.lua`. Skins are purely cosmetic. Players choose one in
**SETTINGS -> PUYO SKIN** ("BY CHARACTER" uses each character's preferred
skin).

## The fastest way: paint over a template

1. **CONTENT -> SKINS**, select *Classic*, press **Z** ->
   **EXPORT SKIN SHEET**. This writes `skin-classic.png` into your mods
   folder. (Command line: `buyo-buyo --headless -- --export-skin classic sheet.png`.)
2. Make a folder `mods/skins/my_skin/`, move the PNG in as `puyos.png`.
3. Create `mods/skins/my_skin/skin.lua`:

   ```lua
   return {
     name = "My Skin",
     author = "you",
     sheet = "puyos.png",
     cell = 64,
   }
   ```

4. Paint over `puyos.png` in any editor (Krita, GIMP, Aseprite, Photoshop,
   LibreSprite...). Keep the grid. Press **F5** to see the result.

## The sheet layout

A sheet is a grid of **16 columns x 7 rows** of square cells
(`cell` = 64 by default, so the full sheet is 1024 x 448 pixels):

```
            col 1   col 2   col 3   ...   col 16          (column = connection mask + 1)
          +-------+-------+-------+     +-------+
 row 1    |  red  |  red  |  red  | ... |  red  |
 row 2    | green | green |  ...  |     |       |
 row 3    | blue  |       |       |     |       |
 row 4    | yellow|       |       |     |       |
 row 5    | purple|       |       |     |       |
 row 6    |nuisance (only column 1 is used)       |
 row 7    | open | blink | happy | dizzy | worried | nuisance face |   <- face overlays
          +-------+-------+-------+     +-------+
```

### Connection masks

Puyos of the same color that touch are drawn **joined**. Each column is
one combination of neighbours, encoded as a mask:

| Bit | Value | Neighbour |
|---|---|---|
| up    | 1 | same color above |
| right | 2 | same color to the right |
| down  | 4 | same color below |
| left  | 8 | same color to the left |

Column = mask + 1. A few examples:

| Column | Mask | Looks like |
|---|---|---|
| 1  | 0  | a lone puyo `o` |
| 2  | 1  | joined upwards |
| 3  | 2  | joined to the right `o-` |
| 6  | 5 (up+down) | a vertical bridge `|o|` |
| 11 | 10 (right+left) | a horizontal bridge `-o-` |
| 16 | 15 | joined on all four sides |

To join seamlessly, draw the connecting part **all the way to the cell
edge**, at the same position the neighbour's connection touches its edge.
The simplest rule: make the connecting "bridge" centered on the cell side,
with the same width in every cell. If joins look broken, export the
Classic sheet and compare.

Don't want connections? Just paste the same lone puyo into all 16 columns.

### Faces (row 7)

Faces are separate overlays drawn on top of any puyo, so one set of eyes
works for every color and connection shape. The engine picks:

| Column | Face | When |
|---|---|---|
| 1 | `open`     | normal |
| 2 | `blink`    | now and then, randomly |
| 3 | `happy`    | while popping |
| 4 | `dizzy`    | the field lost |
| 5 | `worried`  | the stack is dangerously high |
| 6 | nuisance   | the face of nuisance puyos |

If your puyos have faces painted in (or no faces at all), leave row 7 out
(a 1024 x 384 sheet) or set `faces = false`.

## All fields

```lua
return {
  name = "Gems",
  author = "you",
  description = "Faceted jewels.",
  order = 10,                  -- position in lists (lower first)
  cell = 64,                   -- cell size in pixels (8..256)
  sheet = "puyos.png",         -- an image sheet...
  -- paint = function(sheet, cell, skin) end,   -- ...or paint it with code
  faces = true,                -- use row 7 as face overlays
  filter = "linear",           -- "nearest" for crisp pixel art
  colors = {                   -- used for particles, ghosts, UI accents
    { 255, 76, 92 }, { 70, 214, 100 }, { 70, 130, 255 },
    { 255, 210, 50 }, { 186, 96, 255 }, { 205, 212, 232 },
  },
}
```

- **Pixel art**: draw at a small `cell` (16 or 32) and set
  `filter = "nearest"`; the engine scales cells to the field size (48 px)
  without blurring.
- **Colors** are the "identity" of each puyo color for effects. Match them
  to your art or pop particles will look off.

## Painting a skin with code

Instead of `sheet`, a skin can have `paint(sheet, cell, skin)`: it receives
a blank sheet-sized canvas and paints every cell with shapes. The built-in
*Classic* skin works this way - `content/skins/classic/skin.lua` is short
and fully commented. The pattern:

```lua
paint = function(sheet, cell, skin)
  for v = 1, 5 do                                 -- the five colors
    local col = skin.colors[v]
    for mask = 0, 15 do
      local img = gfx.image(cell, cell)           -- paint one cell...
      local sh = gfx.shape():circle(cell / 2, cell / 2, cell * 0.42)
      if mask & 2 ~= 0 then sh:rect(cell / 2, cell * 0.2, cell, cell * 0.6) end -- bridge right
      if mask & 8 ~= 0 then sh:rect(0, cell * 0.2, cell / 2, cell * 0.6) end    -- bridge left
      -- (up/down bridges the same way)
      img:fill(sh, col[1], col[2], col[3])
      sheet:blit(img, mask * cell, (v - 1) * cell) -- ...and put it in place
    end
  end
end,
```

Painting cells into their own small image and `blit`-ing them avoids
bridges spilling into neighbouring cells.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Puyos are plain circles | The skin failed to load; see **CONTENT -> ERRORS** (wrong file name, image too small for the grid...). |
| "expected at least 1024x384" | The sheet must be 16 cells wide and at least 6 rows tall for the chosen `cell`. |
| Thin lines between joined puyos | The bridges don't reach the cell edge, or are narrower/offset differently in the neighbouring cell. |
| Blurry pixel art | `filter = "nearest"`. |
| Wrong faces / faces on nuisance look odd | Check row 7 order: open, blink, happy, dizzy, worried, nuisance. |
