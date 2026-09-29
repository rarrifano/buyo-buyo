-- Particles, rings, rising text popups and flying nuisance "bolts".
local UI = require "view.ui"
local Sprites = require "view.sprites"

local FX = {}
FX.__index = FX

local rnd = math.random

function FX.new() return setmetatable({ parts = {}, rings = {}, pops = {}, bolts = {} }, FX) end

function FX:burst(x, y, col, n, speed)
  for _ = 1, n do
    local a = rnd() * math.pi * 2
    local s = (0.4 + rnd()) * (speed or 3.2)
    self.parts[#self.parts + 1] = {
      x = x,
      y = y,
      vx = math.cos(a) * s,
      vy = math.sin(a) * s - 2.2,
      t = 0,
      life = 26 + rnd(22),
      size = 3 + rnd() * 5,
      col = col,
      spin = rnd() < 0.3,
    }
  end
end

function FX:ring(x, y, col, r0, r1, life)
  self.rings[#self.rings + 1] =
    { x = x, y = y, col = col, r0 = r0, r1 = r1, t = 0, life = life or 20 }
end

function FX:popup(text, x, y, o)
  o = o or {}
  local p = {
    text = text,
    x = x,
    y = y,
    t = 0,
    life = o.life or 70,
    scale = o.scale or 3,
    col = o.col or UI.YELLOW,
    rise = o.rise or 0.7,
    rainbow = o.rainbow,
  }
  self.pops[#self.pops + 1] = p
  return p
end

-- drop a popup early (e.g. the previous chain counter)
function FX:remove_popup(p)
  for i = #self.pops, 1, -1 do
    if self.pops[i] == p then table.remove(self.pops, i) end
  end
end

-- a glowing orb that flies from (x, y) to (tx, ty) along an arc
function FX:bolt(x, y, tx, ty, col, on_hit)
  self.bolts[#self.bolts + 1] =
    { x0 = x, y0 = y, x1 = tx, y1 = ty, t = 0, life = 32, col = col, on_hit = on_hit }
end

function FX:update()
  local parts = self.parts
  for i = #parts, 1, -1 do
    local p = parts[i]
    p.t = p.t + 1
    p.vy = p.vy + 0.2
    p.vx = p.vx * 0.985
    p.x = p.x + p.vx
    p.y = p.y + p.vy
    if p.t >= p.life then table.remove(parts, i) end
  end
  for _, list in ipairs { self.rings, self.pops } do
    for i = #list, 1, -1 do
      local r = list[i]
      r.t = r.t + 1
      if r.t >= r.life then table.remove(list, i) end
    end
  end
  local bolts = self.bolts
  for i = #bolts, 1, -1 do
    local b = bolts[i]
    b.t = b.t + 1
    if b.t >= b.life then
      table.remove(bolts, i)
      if b.on_hit then b.on_hit(b) end
      self:ring(b.x1, b.y1, b.col, 6, 40, 16)
    end
  end
end

function FX:draw()
  for _, r in ipairs(self.rings) do
    local k = r.t / r.life
    local rad = r.r0 + (r.r1 - r.r0) * k
    gfx.blend "add"
    gfx.color(r.col[1], r.col[2], r.col[3], 200 * (1 - k))
    gfx.draw(Sprites.glow, r.x, r.y, 0, rad / 22, rad / 22, 32, 32)
    gfx.blend "alpha"
  end
  for _, p in ipairs(self.parts) do
    local k = 1 - p.t / p.life
    local s = p.size * (0.4 + 0.6 * k)
    if p.spin then
      gfx.color(255, 255, 255, 255 * k)
      gfx.draw(Sprites.sparkle, p.x, p.y, p.t * 0.2, s / 18, s / 18, 32, 32)
    else
      gfx.color(p.col[1], p.col[2], p.col[3], 255 * k)
      gfx.circle(p.x, p.y, s)
      gfx.color(255, 255, 255, 180 * k)
      gfx.circle(p.x - s * 0.3, p.y - s * 0.3, s * 0.35)
    end
  end
  for _, b in ipairs(self.bolts) do
    local k = b.t / b.life
    local e = k * k * (3 - 2 * k)
    local x = b.x0 + (b.x1 - b.x0) * e
    local y = b.y0 + (b.y1 - b.y0) * e - math.sin(k * math.pi) * 120
    gfx.blend "add"
    for tail = 0, 5 do
      local kk = math.max(0, k - tail * 0.03)
      local ee = kk * kk * (3 - 2 * kk)
      local tx = b.x0 + (b.x1 - b.x0) * ee
      local ty = b.y0 + (b.y1 - b.y0) * ee - math.sin(kk * math.pi) * 120
      gfx.color(b.col[1], b.col[2], b.col[3], 150 - tail * 24)
      gfx.draw(Sprites.glow, tx, ty, 0, 0.9 - tail * 0.1, nil, 32, 32)
    end
    gfx.color(255, 255, 255, 255)
    gfx.draw(Sprites.glow, x, y, 0, 0.5, nil, 32, 32)
    gfx.blend "alpha"
  end
  for _, p in ipairs(self.pops) do
    local k = p.t / p.life
    local pop_in = math.min(1, p.t / 6)
    local scale = p.scale * (0.6 + 0.4 * pop_in)
    local alpha = k > 0.75 and 255 * (1 - (k - 0.75) / 0.25) or 255
    local y = p.y - p.t * p.rise
    if p.rainbow then
      UI.rainbow(p.text, p.x, y, scale, p.t, "center", alpha)
    else
      UI.outline(p.text, p.x, y, scale, "center", p.col, nil, alpha)
    end
  end
end

return FX
