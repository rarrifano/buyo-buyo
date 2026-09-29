-- Skin runtime: turns a skin definition (content/skins/<id>/skin.lua) into
-- textures and draws puyos with it.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Sheet layout: 16 columns (connection mask 0..15) x 7 rows of `cell` px.
-- Rows 1-5 colors, row 6 nuisance, row 7 faces (open, blink, happy, dizzy,
-- worried, nuisance). Every cell becomes its own texture, so filtering never
-- bleeds between neighbouring cells.
local Content = require "core.content"

local Skin = {}
Skin.__index = Skin

Skin.FACES = { "open", "blink", "happy", "dizzy", "worried", "nuisance" }

local built = {}

-- the CPU-side sheet (also used by --export-skin)
function Skin.sheet(def)
  local cell = def.cell
  if def.sheet then
    local p, err = Content.path(def, def.sheet)
    if not p then error(err, 0) end
    local img, e = gfx.image_load(p)
    if not img then error(e, 0) end
    local w, h = img:size()
    if w < 16 * cell or h < 6 * cell then
      error(
        string.format(
          "%s is %dx%d, expected at least %dx%d (16 x 6 or 7 cells of %d px)",
          def.sheet,
          w,
          h,
          16 * cell,
          6 * cell,
          cell
        ),
        0
      )
    end
    return img
  end
  local img = gfx.image(16 * cell, 7 * cell)
  local ok, err =
    pcall(def.paint, img, cell, { colors = def.colors or Content.PALETTE, cell = cell })
  if not ok then error("paint() failed: " .. tostring(err), 0) end
  return img
end

function Skin.build(def)
  local img = Skin.sheet(def)
  local cell = def.cell
  local filter = def.filter == "nearest" and "nearest" or "linear"
  local _, h = img:size()
  local sk = setmetatable({
    id = def.id,
    def = def,
    cell = cell,
    body = {},
    face = {},
    faces = def.faces ~= false and h >= 7 * cell,
    colors = def.colors or Content.PALETTE,
  }, Skin)
  for v = 1, 6 do
    sk.body[v] = {}
    for m = 0, 15 do
      sk.body[v][m] = img:crop(m * cell, (v - 1) * cell, cell, cell):texture(filter)
    end
  end
  if sk.faces then
    for k, name in ipairs(Skin.FACES) do
      sk.face[name] = img:crop((k - 1) * cell, 6 * cell, cell, cell):texture(filter)
    end
  end
  return sk
end

-- plain circles: used when no skin can be loaded, so the game never breaks
function Skin.fallback()
  if built["__fallback"] then return built["__fallback"] end
  local cell = 32
  local sk = setmetatable({
    id = "__fallback",
    cell = cell,
    body = {},
    face = {},
    faces = false,
    colors = Content.PALETTE,
  }, Skin)
  for v = 1, 6 do
    local img = gfx.image(cell, cell)
    local c = Content.PALETTE[v]
    img:fill(gfx.shape():circle(cell / 2, cell / 2, cell * 0.44), c[1], c[2], c[3], 255)
    local tex = img:texture()
    sk.body[v] = {}
    for m = 0, 15 do
      sk.body[v][m] = tex
    end
  end
  built["__fallback"] = sk
  return sk
end

function Skin.get(id)
  local def = Content.pick("skins", id)
  if not def then return Skin.fallback() end
  if built[def.id] then return built[def.id] end
  local ok, sk = pcall(Skin.build, def)
  if not ok then
    Content.report("skins", def.id, tostring(sk))
    sk = Skin.fallback()
  end
  built[def.id] = sk
  return sk
end

function Skin.clear_cache() built = {} end

function Skin:color(v) return self.colors[v] or Content.PALETTE[v] end

-- draw one puyo centred at (x, y) with diameter `size`
function Skin:puyo(v, x, y, size, mask, face, alpha, sx, sy)
  local k = size / self.cell
  local h = self.cell / 2
  sx, sy = k * (sx or 1), k * (sy or 1)
  gfx.color(255, 255, 255, alpha or 255)
  local row = self.body[v] or self.body[1]
  gfx.draw(row[mask or 0] or row[0], x, y, 0, sx, sy, h, h)
  if self.faces and face ~= false then
    local f = v == 6 and self.face.nuisance or self.face[face or "open"]
    if f then gfx.draw(f, x, y, 0, sx, sy, h, h) end
  end
end

return Skin
