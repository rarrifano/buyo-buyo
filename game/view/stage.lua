-- Stage runtime: backgrounds from content/stages/<id>/stage.lua.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- A stage can combine, from back to front:
--   gradient = { top = {r,g,b}, bottom = {r,g,b} }   (or color = {r,g,b})
--   layers   = { { image = "sky.png", scroll_x = 0.2, tile = true, ... }, ... }
--   draw(state, t)                                   scripted drawing on top
-- plus update(state, t) / init(state) for scripted animation.
local Content = require "core.content"

local Stage = {}
Stage.__index = Stage

local DEFAULT_TOP, DEFAULT_BOTTOM = { 44, 30, 96 }, { 16, 12, 44 }

local function rgb(c, d)
  if type(c) == "table" and type(c[1]) == "number" then return c end
  return d
end

function Stage.new(def)
  local st = setmetatable({ def = def, t = 0, state = {}, layers = {} }, Stage)
  local top, bottom = DEFAULT_TOP, DEFAULT_BOTTOM
  if def and type(def.gradient) == "table" then
    top, bottom = rgb(def.gradient.top, top), rgb(def.gradient.bottom, bottom)
  elseif def and def.color then
    top = rgb(def.color, top)
    bottom = top
  end
  local img = gfx.image(4, 256)
  img:gradient(top[1], top[2], top[3], 255, bottom[1], bottom[2], bottom[3], 255)
  st.grad = img:texture()
  if def then
    for i, L in ipairs(def.layers or {}) do
      if type(L) == "table" and type(L.image) == "string" then
        local p, err = Content.path(def, L.image)
        local tex, w, h
        if p then
          tex, w, h = gfx.load(p, L.filter)
        end
        if tex then
          st.layers[#st.layers + 1] = {
            tex = tex,
            w = w,
            h = h,
            x = tonumber(L.x) or 0,
            y = tonumber(L.y) or 0,
            sx = tonumber(L.scroll_x) or 0,
            sy = tonumber(L.scroll_y) or 0,
            tile = L.tile == true,
            scale = tonumber(L.scale) or 1,
            fit = L.fit == true,
            alpha = tonumber(L.alpha) or 255,
            blend = L.blend == "add" and "add" or "alpha",
            color = rgb(L.color, { 255, 255, 255 }),
          }
        else
          Content.report("stages", def.id, string.format("layer %d: %s", i, tostring(err or w)))
        end
      end
    end
    Content.call(def, "init", st.state)
  end
  return st
end

function Stage:update()
  self.t = self.t + 1
  if self.def then Content.call(self.def, "update", self.state, self.t) end
end

local function draw_layer(L, t)
  local sw, sh = L.w * L.scale, L.h * L.scale
  local sx, sy = L.scale, L.scale
  if L.fit then
    sx, sy = 1280 / L.w, 720 / L.h
    sw, sh = 1280, 720
  end
  gfx.blend(L.blend)
  gfx.color(L.color[1], L.color[2], L.color[3], L.alpha)
  local ox = L.x + t * L.sx
  local oy = L.y + t * L.sy
  if L.tile then
    ox = -(ox % sw)
    oy = -(oy % sh)
    local y = oy
    while y < 720 do
      local x = ox
      while x < 1280 do
        gfx.draw(L.tex, x, y, 0, sx, sy)
        x = x + sw
      end
      y = y + sh
    end
  else
    gfx.draw(L.tex, ox, oy, 0, sx, sy)
  end
end

function Stage:draw()
  gfx.blend "alpha"
  gfx.color(255, 255, 255)
  gfx.stretch(self.grad, 0, 0, 1280, 720)
  for _, L in ipairs(self.layers) do
    draw_layer(L, self.t)
  end
  gfx.blend "alpha"
  if self.def then Content.call(self.def, "draw", self.state, self.t) end
  gfx.blend "alpha"
  gfx.color(255, 255, 255)
end

return Stage
