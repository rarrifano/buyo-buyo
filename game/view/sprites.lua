-- Engine UI sprites painted at startup: effects and nuisance tray icons.
-- (Puyos themselves come from skins, see view/skin.lua and content/skins.)
-- SPDX-License-Identifier: GPL-2.0-or-later
local Sprites = {}

local S = 64
local C = S / 2

local function shape() return gfx.shape() end

local function star_points(cx, cy, ro, ri, n, rot)
  local pts = {}
  for k = 0, n * 2 - 1 do
    local a = rot + k * math.pi / n
    local r = (k % 2 == 0) and ro or ri
    pts[#pts + 1] = cx + math.cos(a) * r
    pts[#pts + 1] = cy + math.sin(a) * r
  end
  return pts
end

local function icon_rock()
  local img = gfx.image(S, S)
  local sh = shape():rect(7, 12, 50, 42, 12)
  img:fill(sh, 58, 52, 62, 255, { soft = 1.2 })
  img:fill(sh, 150, 140, 150, 255, { inset = 2.5 })
  img:fill(sh, 190, 182, 190, 255, { inset = 7, soft = 6, dx = -3, dy = -4 })
  img:fill(shape():capsule(22, 26, 30, 36, 1.6):capsule(30, 36, 27, 46, 1.6), 90, 80, 95, 220)
  img:fill(shape():ellipse(22, 20, 9, 4, -0.3), 255, 255, 255, 150, { soft = 2 })
  return img:texture()
end

local function icon_star()
  local img = gfx.image(S, S)
  local sh = shape():poly(star_points(C, C + 2, 29, 13, 5, -math.pi / 2))
  img:fill(sh, 110, 60, 10, 255, { soft = 1.2 })
  img:fill(sh, 255, 196, 40, 255, { inset = 2.5 })
  img:fill(sh, 255, 240, 150, 255, { inset = 7, soft = 6, dx = -2, dy = -3 })
  return img:texture()
end

local function icon_moon()
  local img = gfx.image(S, S)
  local sh = shape():circle(C, C, 27):circle(C + 13, C - 9, 22, "sub")
  img:fill(sh, 100, 70, 20, 255, { soft = 1.2 })
  img:fill(sh, 255, 222, 110, 255, { inset = 2.5 })
  img:fill(sh, 255, 248, 200, 255, { inset = 7, soft = 6, dx = -2, dy = -2 })
  return img:texture()
end

local function icon_crown()
  local img = gfx.image(S, S)
  local sh = shape():poly { 6, 52, 6, 20, 19, 34, 32, 12, 45, 34, 58, 20, 58, 52 }
  img:fill(sh, 100, 60, 10, 255, { soft = 1.2 })
  img:fill(sh, 255, 190, 40, 255, { inset = 2.5 })
  img:fill(sh, 255, 236, 140, 255, { inset = 7, soft = 6, dx = -2, dy = -3 })
  for _, p in ipairs { { 6, 18 }, { 32, 10 }, { 58, 18 } } do
    img:fill(shape():circle(p[1], p[2], 5), 255, 90, 110, 255)
  end
  img:fill(shape():circle(32, 42, 5), 90, 170, 255, 255)
  return img:texture()
end

local function icon_comet()
  local img = gfx.image(S, S)
  img:fill(shape():capsule(10, 54, 36, 28, 7), 120, 200, 255, 140, { soft = 6 })
  local sh = shape():poly(star_points(40, 24, 20, 9, 5, -math.pi / 2))
  img:fill(sh, 40, 60, 120, 255, { soft = 1.2 })
  img:fill(sh, 140, 210, 255, 255, { inset = 2.5 })
  img:fill(sh, 230, 250, 255, 255, { inset = 6, soft = 5 })
  return img:texture()
end

function Sprites.build()
  local img = gfx.image(S, S)
  img:fill(shape():capsule(16, 16, 48, 48, 5.5):capsule(16, 48, 48, 16, 5.5), 255, 255, 255, 255, { soft = 1.2 })
  Sprites.x_mark = img:texture()

  img = gfx.image(S, S)
  img:fill(shape():circle(C, C, 22), 255, 255, 255, 255, { soft = 20 })
  Sprites.glow = img:texture()

  img = gfx.image(S, S)
  img:fill(shape():poly(star_points(C, C, 30, 6, 4, 0)), 255, 255, 255, 255, { soft = 2 })
  img:fill(shape():circle(C, C, 8), 255, 255, 255, 255, { soft = 6 })
  Sprites.sparkle = img:texture()

  Sprites.icons = {
    rock = icon_rock(), star = icon_star(), moon = icon_moon(), crown = icon_crown(), comet = icon_comet(),
  }
end

return Sprites
