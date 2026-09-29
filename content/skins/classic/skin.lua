-- Classic skin: glossy gel blobs with googly eyes, painted entirely by code.
--
-- Every skin produces the same "sheet" layout (see docs/SKINS.md):
--   16 columns x 7 rows of `cell` x `cell` pixels
--   rows 1-5 : red, green, blue, yellow, purple puyos
--   row  6   : nuisance (only column 1 is used)
--   row  7   : face overlays drawn on top of any puyo:
--              open, blink, happy, dizzy, worried, nuisance-face
--   column   : connection mask + 1  (mask bits: 1 up, 2 right, 4 down, 8 left)
--
-- An image skin just points `sheet` at a PNG with that layout. This one paints
-- the sheet with the canvas API instead (gfx.image / gfx.shape / img:fill).
-- Want a PNG to start drawing from? Run:  buyo-buyo --export-skin classic my.png
return {
  name = "Classic",
  author = "Buyo Buyo",
  description = "Glossy gel blobs painted by code. Read skin.lua to learn the canvas API.",
  order = 1,
  cell = 64,
  faces = true,
  -- used for particles, ghosts and UI accents (index = puyo color, 6 = nuisance)
  colors = {
    { 255, 76, 92 }, { 70, 214, 100 }, { 70, 130, 255 }, { 255, 210, 50 }, { 186, 96, 255 }, { 205, 212, 232 },
  },

  paint = function(sheet, cell, skin)
    local C = cell / 2
    local R = cell * 0.445

    -- the blob outline: a circle plus "bridges" towards connected neighbours.
    -- Bridges overshoot the cell so they meet the neighbour's bridge seamlessly.
    local function blob(mask)
      local sh = gfx.shape():circle(C, C, R)
      local hw, E = R * 0.74, cell * 0.4
      if mask & 1 ~= 0 then sh:rect(C - hw, -E, hw * 2, C + E) end
      if mask & 2 ~= 0 then sh:rect(C, C - hw, C + E, hw * 2) end
      if mask & 4 ~= 0 then sh:rect(C - hw, C, hw * 2, C + E) end
      if mask & 8 ~= 0 then sh:rect(-E, C - hw, C + E, hw * 2) end
      return sh
    end

    local function shade(col, k) return col[1] * k, col[2] * k, col[3] * k end

    local function body(mask, col)
      local img = gfx.image(cell, cell)
      local sh = blob(mask)
      local r, g, b = shade(col, 0.27)
      img:fill(sh, r, g, b, 255, { soft = 1.2 })                                  -- dark outline
      r, g, b = shade(col, 0.64)
      img:fill(sh, r, g, b, 255, { inset = cell * 0.037, soft = 1.2 })            -- rim
      r, g, b = shade(col, 0.85)
      img:fill(sh, r, g, b, 255, { inset = cell * 0.07, soft = 4, dx = -1.2, dy = -1.8 })
      img:fill(sh, col[1], col[2], col[3], 255, { inset = cell * 0.14, soft = 10, dx = -3, dy = -4 }) -- core
      return img
    end

    local function highlight(img)
      img:fill(gfx.shape():ellipse(C - R * 0.42, C - R * 0.50, R * 0.30, R * 0.16, -0.62), 255, 255, 255, 205, { soft = 2.2 })
      img:fill(gfx.shape():circle(C - R * 0.02, C - R * 0.70, R * 0.065), 255, 255, 255, 170, { soft = 1.4 })
    end

    local ink = { 34, 26, 52 }
    local function face(kind)
      local img = gfx.image(cell, cell)
      highlight(img)
      for side = -1, 1, 2 do
        local ex, ey = C + side * R * 0.35, C + R * 0.08
        if kind == "blink" then
          img:fill(gfx.shape():capsule(ex - R * 0.15, ey + R * 0.04, ex + R * 0.15, ey + R * 0.04, R * 0.055), ink[1], ink[2], ink[3], 235)
        elseif kind == "happy" then
          img:fill(gfx.shape():capsule(ex - R * 0.16, ey + R * 0.06, ex, ey - R * 0.10, R * 0.06)
                              :capsule(ex, ey - R * 0.10, ex + R * 0.16, ey + R * 0.06, R * 0.06), ink[1], ink[2], ink[3], 240)
        elseif kind == "dizzy" then
          local d = R * 0.13
          img:fill(gfx.shape():capsule(ex - d, ey - d, ex + d, ey + d, R * 0.05)
                              :capsule(ex - d, ey + d, ex + d, ey - d, R * 0.05), ink[1], ink[2], ink[3], 240)
        else -- open / worried
          local sclera = gfx.shape():ellipse(ex, ey, R * 0.20, R * 0.27)
          img:fill(sclera, ink[1], ink[2], ink[3], 210, { inset = -1.6, soft = 1.2 })
          img:fill(sclera, 255, 255, 255, 255)
          local px, py = ex - side * R * 0.05, ey + R * 0.07
          if kind == "worried" then py = ey - R * 0.02 end
          img:fill(gfx.shape():ellipse(px, py, R * 0.11, R * 0.16), ink[1], ink[2], ink[3], 255)
          img:fill(gfx.shape():circle(px - R * 0.04, py - R * 0.07, R * 0.045), 255, 255, 255, 255)
          if kind == "worried" then
            img:fill(gfx.shape():capsule(ex - side * R * 0.16, ey - R * 0.46, ex + side * R * 0.14, ey - R * 0.36, R * 0.045),
                     ink[1], ink[2], ink[3], 230)
          end
        end
      end
      return img
    end

    local function nuisance_face()
      local img = gfx.image(cell, cell)
      highlight(img)
      local k = { 52, 52, 76 }
      for side = -1, 1, 2 do
        local ex, ey = C + side * R * 0.30, C + R * 0.10
        img:fill(gfx.shape():ellipse(ex, ey, R * 0.10, R * 0.17), k[1], k[2], k[3], 255)
        img:fill(gfx.shape():capsule(ex + side * R * 0.18, ey - R * 0.40, ex - side * R * 0.10, ey - R * 0.25, R * 0.05),
                 k[1], k[2], k[3], 235)
      end
      img:fill(gfx.shape():capsule(C - R * 0.14, C + R * 0.50, C + R * 0.14, C + R * 0.50, R * 0.045), k[1], k[2], k[3], 200)
      return img
    end

    -- rows 1..6: bodies for every color and connection mask
    for v = 1, 6 do
      for mask = 0, (v == 6 and 0 or 15) do
        sheet:blit(body(mask, skin.colors[v]), mask * cell, (v - 1) * cell)
      end
    end
    -- row 7: face overlays
    for k, kind in ipairs { "open", "blink", "happy", "dizzy", "worried" } do
      sheet:blit(face(kind), (k - 1) * cell, 6 * cell)
    end
    sheet:blit(nuisance_face(), 5 * cell, 6 * cell)
  end,
}
