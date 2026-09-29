-- Draws one player's side: field, falling pair, ghost, NEXT box, nuisance
-- tray, score, and per-field effects. Purely visual: it reads the Player and
-- reacts to its events, so it stays correct across netplay rollbacks.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Rules = require "puyo.rules"
local Board = require "puyo.board"
local Sprites = require "view.sprites"
local UI = require "view.ui"
local FX = require "view.fx"
local U = require "core.util"

local W, H, VIS = Rules.COLS, Rules.ROWS, Rules.VISIBLE
local SUB = Rules.SUB
local GARBAGE = Rules.GARBAGE
local CELL = 48
local idx = Board.idx

local Field = {}
Field.__index = Field
Field.CELL = CELL

local TRAY_UNITS = {
  { 1440, "comet" }, { 720, "crown" }, { 360, "moon" }, { 180, "star" },
  { 30, "rock" }, { 6, "big" }, { 1, "small" },
}

local CHAIN_COLORS = {
  { 255, 255, 255 }, { 255, 240, 130 }, { 255, 214, 80 }, { 255, 170, 60 },
  { 255, 120, 70 }, { 255, 80, 110 }, { 255, 90, 210 }, { 190, 120, 255 },
}

-- side: -1 = left player, 1 = right player; opts.skin = Skin, opts.ghost = bool
function Field.new(player, x, y, side, opts)
  opts = opts or {}
  return setmetatable({
    p = player, x = x, y = y, side = side, skin = opts.skin,
    w = W * CELL, h = VIS * CELL,
    fx = FX.new(),
    squash = {},
    shake = 0, ox = 0, oy = 0,
    drop = 0, drop_v = 0, dead = false,
    formula = nil, formula_t = 0,
    banner_t = 0,
    next_t = 0,
    tray_bump = 0, tray_last = 0,
    ghost = opts.ghost ~= false,
    pop_ref = nil, popset = nil,
    t = 0,
    danger = false,
    incoming = 0,
  }, Field)
end

-- a new round started: forget visual state
function Field:reset()
  self.fx = FX.new()
  self.squash = {}
  self.shake, self.drop, self.drop_v, self.dead = 0, 0, 0, false
  self.formula_t, self.banner_t, self.next_t, self.tray_bump, self.tray_last = 0, 0, 0, 0, 0
  self.pop_ref, self.popset, self.chain_popup = nil, nil, nil
end

-- screen centre of a board cell (y in rows, may be fractional)
function Field:center(x, y)
  return self.x + (x - 0.5) * CELL, self.y + (VIS - y + 0.5) * CELL
end

-- where nuisance icons are shown (targets for attack bolts)
function Field:tray_point()
  return self.x + 70, self.y - 34
end

------------------------------------------------------------------------
-- events
------------------------------------------------------------------------

function Field:on_event(name, d)
  local p = self.p
  if name == "landed_cell" then
    self.squash[d.i] = 8
  elseif name == "pop" then
    local sx, sy, n = 0, 0, 0
    for _, g in ipairs(d.groups) do
      for _, i in ipairs(g.cells) do
        local cx, cy = self:center(Board.xy(i))
        sx, sy, n = sx + cx, sy + cy, n + 1
      end
    end
    local text = d.chain .. " CHAIN!"
    local scale = d.chain >= 4 and 4 or 3
    local half = #text * 4 * scale + 6
    local cx = U.clamp(sx / n, self.x + half, self.x + self.w - half)
    local cy = U.clamp(sy / n, self.y + 40, self.y + self.h - 40)
    self.last_pop_x, self.last_pop_y = cx, cy
    if self.chain_popup then self.fx:remove_popup(self.chain_popup) end
    self.chain_popup = nil
    if d.chain >= 2 then
      local col = CHAIN_COLORS[math.min(d.chain, #CHAIN_COLORS)]
      self.chain_popup = self.fx:popup(text, cx, cy - 16, { scale = scale, col = col, life = 80 })
    end
    self.formula = string.format("%d x %d", d.puyos * 10, d.bonus)
    self.formula_t = 75
  elseif name == "burst" then
    for _, e in ipairs(d.cleared) do
      local cx, cy = self:center(Board.xy(e.i))
      local col = self.skin:color(e.v)
      self.fx:burst(cx, cy, col, e.v == GARBAGE and 4 or 7, 3.2)
      self.fx:ring(cx, cy, col, 8, 42, 18)
    end
  elseif name == "garbage" then
    self.incoming = d.n
  elseif name == "land" then
    if self.incoming > 0 and p.state == "garbage" then
      self.shake = math.min(14, 3 + self.incoming / 3)
      self.incoming = 0
    end
  elseif name == "all_clear" then
    self.banner_t = 160
  elseif name == "spawn" then
    self.next_t = 1
  end
end

------------------------------------------------------------------------
-- update
------------------------------------------------------------------------

function Field:update()
  self.t = self.t + 1
  self.fx:update()
  for i, s in pairs(self.squash) do
    if s <= 1 then self.squash[i] = nil else self.squash[i] = s - 1 end
  end
  if self.shake > 0 then
    self.shake = self.shake * 0.86
    if self.shake < 0.4 then self.shake = 0 end
  end
  self.ox = self.shake > 0 and (math.random() * 2 - 1) * self.shake or 0
  self.oy = self.shake > 0 and (math.random() * 2 - 1) * self.shake * 0.6 or 0
  if self.formula_t > 0 then self.formula_t = self.formula_t - 1 end
  if self.banner_t > 0 then self.banner_t = self.banner_t - 1 end
  if self.next_t > 0 then self.next_t = math.max(0, self.next_t - 1 / 9) end
  -- the dead player's stack slides out of the field
  if self.p.dead then
    if not self.dead then
      self.dead = true
      self.drop_v = -4
    end
    self.drop_v = self.drop_v + 0.7
    self.drop = self.drop + self.drop_v
  elseif self.dead then
    self.dead, self.drop, self.drop_v = false, 0, 0 -- revived by a rollback
  end
  local pending = self.p.pending
  if pending > self.tray_last then self.tray_bump = 1 end
  self.tray_last = pending
  if self.tray_bump > 0 then self.tray_bump = math.max(0, self.tray_bump - 0.08) end
  local b = self.p.board
  local R = self.p.match.R
  self.danger = not self.p.dead and (b:height(R.death_x) >= 10 or b:height(math.max(1, R.death_x - 1)) >= 11
                                     or b:height(math.min(6, R.death_x + 1)) >= 11)
end

-- set of cells currently popping (derived from the simulation state)
function Field:popping()
  local pop = self.p.pop
  if not pop then return nil end
  if self.pop_ref ~= pop.groups then
    local set = {}
    for _, g in ipairs(pop.groups) do
      for _, i in ipairs(g.cells) do set[i] = true end
    end
    for _, i in ipairs(pop.garbage) do set[i] = true end
    self.pop_ref, self.popset = pop.groups, set
  end
  return self.popset
end

------------------------------------------------------------------------
-- drawing
------------------------------------------------------------------------

local function connections(c, aoff, x, y, v)
  local m = 0
  if y < VIS then local j = idx(x, y + 1); if c[j] == v and aoff[j] == 0 then m = m | 1 end end
  if x < W then local j = idx(x + 1, y); if c[j] == v and aoff[j] == 0 then m = m | 2 end end
  if y > 1 then local j = idx(x, y - 1); if c[j] == v and aoff[j] == 0 then m = m | 4 end end
  if x > 1 then local j = idx(x - 1, y); if c[j] == v and aoff[j] == 0 then m = m | 8 end end
  return m
end

function Field:draw_frame()
  local x, y, w, h = self.x, self.y, self.w, self.h
  gfx.color(10, 8, 30, 218)
  gfx.rect(x, y, w, h)
  gfx.color(255, 255, 255, 8)
  for r = 0, VIS - 1 do
    for c = 0, W - 1 do
      if (r + c) % 2 == 0 then gfx.rect(x + c * CELL, y + r * CELL, CELL, CELL) end
    end
  end
  local pulse = self.danger and (0.5 + 0.5 * math.sin(self.t * 0.3)) or 0
  if self.danger then
    gfx.color(255, 40, 80, 40 * pulse)
    gfx.rect(x, y, w, h)
  end
  local R = self.p.match.R
  local cx, cy = self:center(R.death_x, R.death_y)
  gfx.color(255, 70, 100, 110 + 130 * pulse)
  gfx.draw(Sprites.x_mark, cx, cy, 0, CELL / 64 * 0.85, nil, 32, 32)
  local bc = self.danger and { 255, 120 + 100 * (1 - pulse), 140 } or UI.BORDER
  UI.frame(x - 8, y - 8, w + 16, h + 16, bc)
end

function Field:draw_cells()
  local p, skin = self.p, self.skin
  local c, aoff = p.board.c, p.aoff
  local popset = self:popping()
  local pt = p.pop and p.pop.t or 0
  local pop_time = p.match.R.pop_time
  local shrink_from = pop_time - math.min(14, pop_time // 2)
  for y = 1, H do
    for x = 1, W do
      local i = idx(x, y)
      local v = c[i]
      if v ~= 0 then
        local off = aoff[i]
        local cx, cy = self:center(x, y + off / SUB)
        cy = cy + self.drop
        if cy > self.y - CELL and cy < self.y + self.h + CELL then
          local mask = 0
          if v ~= GARBAGE and off == 0 and y <= VIS then mask = connections(c, aoff, x, y, v) end
          local popping = popset and popset[i]
          local face = "open"
          if popping then face = "happy"
          elseif p.dead then face = "dizzy"
          elseif self.danger then face = "worried"
          elseif (p.frame + i * 53) % 290 < 7 then face = "blink" end
          if popping and pt > shrink_from then
            local k = (pt - shrink_from) / (pop_time - shrink_from)
            skin:puyo(v, cx, cy, CELL * (1 - 0.55 * k), mask, face, 255 * (1 - k))
          else
            local sx, sy = 1, 1
            local sq = self.squash[i]
            if sq then
              local k = sq / 8
              sx, sy = 1 + 0.16 * k, 1 - 0.16 * k
              cy = cy + CELL * 0.08 * k
            end
            skin:puyo(v, cx, cy, CELL, mask, face, 255, sx, sy)
            if popping and (pt // 4) % 2 == 0 then
              gfx.blend("add")
              gfx.color(255, 255, 255, 200)
              gfx.draw(Sprites.glow, cx, cy, 0, CELL / 44, nil, 32, 32)
              gfx.blend("alpha")
            end
          end
        end
      end
    end
  end
end

function Field:draw_piece()
  local p, skin = self.p, self.skin
  local pc = p.piece
  if not pc or p.dead then return end
  if self.ghost then
    local x1, y1, x2, y2 = p:landing()
    for k = 1, 2 do
      local gx, gy, col = x1, y1, pc.c1
      if k == 2 then gx, gy, col = x2, y2, pc.c2 end
      if gy <= VIS then
        local cx, cy = self:center(gx, gy)
        local cc = skin:color(col)
        gfx.color(cc[1], cc[2], cc[3], 130)
        gfx.circle(cx, cy, CELL * 0.17)
        gfx.color(255, 255, 255, 110)
        gfx.circle(cx - 2.5, cy - 2.5, CELL * 0.055)
      end
    end
  end
  local px, py = self:center(pc.x, pc.y / SUB)
  local sx, sy = px + math.sin(pc.ang) * CELL, py - math.cos(pc.ang) * CELL
  local pulse = 0.5 + 0.5 * math.sin(p.frame * 0.3)
  gfx.blend("add")
  gfx.color(255, 255, 255, 45 + 70 * pulse)
  gfx.draw(Sprites.glow, px, py, 0, 1.25, nil, 32, 32)
  gfx.blend("alpha")
  skin:puyo(pc.c2, sx, sy, CELL, 0, "open")
  skin:puyo(pc.c1, px, py, CELL, 0, "open")
end

function Field:draw()
  local px, py = gfx.offset(self.ox, self.oy)
  self:draw_frame()
  gfx.clip(self.x, self.y, self.w, self.h)
  self:draw_cells()
  self:draw_piece()
  gfx.clip()
  if self.banner_t > 0 then
    local k = math.min(1, (160 - self.banner_t) / 10)
    local cx = self.x + self.w / 2
    local a = math.min(255, self.banner_t * 8)
    UI.rainbow("ALL", cx, self.y + self.h * 0.30, 5 * k, self.t, "center", a)
    UI.rainbow("CLEAR!", cx, self.y + self.h * 0.30 + 56, 5 * k, self.t, "center", a)
  end
  gfx.offset(px, py)
  self.fx:draw()
end

-- NEXT box at (bx, by): 112 x 206
function Field:draw_next(bx, by)
  UI.panel(bx, by, 112, 206)
  UI.text("NEXT", bx + 56, by + 12, 2, "center", UI.GRAY)
  local p, skin = self.p, self.skin
  local n1, n2 = p:next_pair(1), p:next_pair(2)
  local near = self.side < 0 and bx + 38 or bx + 112 - 38
  local far = self.side < 0 and bx + 80 or bx + 112 - 80
  local e = U.ease_out_cubic(1 - self.next_t)
  local function pair(pr, x, yb, size, alpha)
    skin:puyo(pr[2], x, yb - size, size, 0, "open", alpha)
    skin:puyo(pr[1], x, yb, size, 0, "open", alpha)
  end
  pair(n1, U.lerp(far, near, e), U.lerp(by + 184, by + 106, e), U.lerp(34, 46, e))
  pair(n2, far, by + 184 + 30 * (1 - e), 34, 255 * e)
end

function Field:draw_tray()
  local n = self.p.pending
  if n <= 0 then return end
  local icons = {}
  for _, u in ipairs(TRAY_UNITS) do
    while n >= u[1] and #icons < 6 do
      icons[#icons + 1] = u[2]
      n = n - u[1]
    end
  end
  local held = self.p.opponent and self.p.opponent.chaining
  local bump = 1 + self.tray_bump * 0.35
  for k, name in ipairs(icons) do
    local cx = self.x + 24 + (k - 1) * 48
    local cy = self.y - 34
    if held then cy = cy + math.sin(self.t * 0.5 + k) * 2 end
    if name == "small" then
      self.skin:puyo(GARBAGE, cx, cy + 6, 26 * bump, 0)
    elseif name == "big" then
      self.skin:puyo(GARBAGE, cx, cy, 42 * bump, 0)
    else
      gfx.color(255, 255, 255)
      gfx.draw(Sprites.icons[name], cx, cy, 0, 44 / 64 * bump, nil, 32, 32)
    end
  end
end

function Field:draw_score()
  local cx = self.x + self.w / 2
  local y = self.y + self.h + 16
  if self.formula_t > 0 then
    UI.text(self.formula, cx, y, 3, "center", UI.YELLOW)
  else
    UI.text(U.pad_number(self.p.score, 8), cx, y, 3, "center", UI.WHITE)
  end
end

return Field
