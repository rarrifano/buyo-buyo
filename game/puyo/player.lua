-- One side of a versus match: the field, the falling pair and the state
-- machine that resolves chains and receives nuisance.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- States: wait -> spawn_wait -> move -> fall -> (pop -> fall)* -> garbage? -> spawn_wait ...
--         and finally "dead".
--
-- Determinism rules (rollback netplay replays these frames on both machines):
--   * only integers: positions are fixed point (Rules.SUB per row),
--   * no pairs() iteration, no math.random, no clocks,
--   * input is a bitmask per frame; "pressed" edges are derived here.
-- The player never touches graphics or audio: it reports what happens via
-- match:emit(player, name, data).
local Rules = require "puyo.rules"
local Board = require "puyo.board"
local U = require "core.util"

local W, H, VIS = Rules.COLS, Rules.ROWS, Rules.VISIBLE
local N = W * H
local SUB = Rules.SUB
local GARBAGE = Rules.GARBAGE
local idx = Board.idx

-- satellite offset per rotation: 0 up, 1 right, 2 down, 3 left
local RDX = { [0] = 0, 1, 0, -1 }
local RDY = { [0] = 1, 0, -1, 0 }

-- input bits
local B_LEFT, B_RIGHT, B_UP, B_DOWN, B_ROTL, B_ROTR = 1, 2, 4, 8, 16, 32

local Player = {}
Player.__index = Player
Player.RDX, Player.RDY = RDX, RDY
Player.BUTTONS = { left = B_LEFT, right = B_RIGHT, up = B_UP, down = B_DOWN, rot_l = B_ROTL, rot_r = B_ROTR }

-- coerce a (possibly missing / float) value coming from a mode hook to an integer
local function toint(v, default)
  if type(v) ~= "number" then return default end
  return math.tointeger(math.floor(v)) or default
end

local function zeros(n)
  local t = {}
  for i = 1, n do t[i] = 0 end
  return t
end

function Player.new(id, match)
  local p = setmetatable({ id = id, match = match }, Player)
  p.board = Board.new()
  p.aoff, p.avel, p.adelay = zeros(N), zeros(N), zeros(N) -- falling animation per cell
  p.rng = U.rng(1)
  p.hard_drop_enabled = true
  p:reset(1)
  return p
end

-- fresh field for a new round
function Player:reset(seed)
  local c = self.board.c
  for i = 1, N do
    c[i] = 0
    self.aoff[i], self.avel[i], self.adelay[i] = 0, 0, 0
  end
  self.rng.s = U.rng(seed).s
  self.piece = nil
  self.pop = nil
  self.seq_i = 0
  self.state = "wait"
  self.timer = 0
  self.frame = 0
  self.score = 0
  self.chain = 0
  self.max_chain = 0
  self.chaining = false
  self.pending = 0      -- nuisance waiting to fall on us
  self.leftover = 0     -- score not yet converted into nuisance
  self.all_clear = false
  self.dead = false
  self.das_dir, self.das_t = 0, 0
  self.lock_timer, self.lock_resets, self.kicks, self.quick_turn = 0, 0, 0, 0
  self.grounded = false
  self.prev_mask = 0
  self.pieces, self.sent, self.chains = 0, 0, 0
end

function Player:emit(name, data) self.match:emit(self, name, data) end

function Player:start() self:prepare_spawn() end

-- next pairs for the preview (n = 1 is the very next one)
function Player:next_pair(n) return self.match.seq:get(self.seq_i + n) end

-- is cell i in the middle of a falling animation?
function Player:animating(i) return self.aoff[i] > 0 end

-- queue nuisance on this player (used by the match and by modes)
function Player:add_garbage(n)
  if n > 0 then self.pending = self.pending + n end
end

------------------------------------------------------------------------
-- collision
------------------------------------------------------------------------

local function free(c, x, y)
  if x < 1 or x > W or y < 1 then return false end
  if y > H then return y == H + 1 end -- a single open row above the field
  return c[(y - 1) * W + x] == 0
end

-- does the pair fit with the pivot at column x, sub-row y?
function Player:fits(x, y, r)
  local c = self.board.c
  local y0 = y // SUB
  local sx, sy = x + RDX[r], y0 + RDY[r]
  if not free(c, x, y0) or not free(c, sx, sy) then return false end
  if y % SUB ~= 0 and (not free(c, x, y0 + 1) or not free(c, sx, sy + 1)) then return false end
  return true
end

-- rows where each puyo of the pair would land (ghost / AI)
function Player:landing()
  local p = self.piece
  local b = self.board
  local sx = p.x + RDX[p.r]
  if p.r == 0 then
    local h = b:height(p.x)
    return p.x, h + 1, sx, h + 2
  elseif p.r == 2 then
    local h = b:height(p.x)
    return p.x, h + 2, sx, h + 1
  end
  return p.x, b:height(p.x) + 1, sx, b:height(sx) + 1
end

------------------------------------------------------------------------
-- piece control
------------------------------------------------------------------------

function Player:touched()
  local R = self.match.R
  if self.grounded and self.lock_resets < R.lock_resets then
    self.lock_timer = 0
    self.lock_resets = self.lock_resets + 1
  end
end

function Player:shift(dir)
  local p = self.piece
  if self:fits(p.x + dir, p.y, p.r) then
    p.x = p.x + dir
    self:touched()
    self:emit("move")
    return true
  end
  return false
end

function Player:set_rotation(r, turns)
  local p = self.piece
  p.r = r
  p.tang = p.tang + turns * math.pi / 2 -- visual only
  self:touched()
  self:emit("rotate")
end

function Player:rotate(dir)
  local p = self.piece
  local R = self.match.R
  local nr = (p.r + dir) % 4
  if self:fits(p.x, p.y, nr) then
    self:set_rotation(nr, dir)
    return true
  end
  if nr == 1 or nr == 3 then
    -- wall / stack kick: push the pivot away from the obstacle
    local kx = -RDX[nr]
    if self:fits(p.x + kx, p.y, nr) then
      p.x = p.x + kx
      self:set_rotation(nr, dir)
      return true
    end
  elseif nr == 2 then
    -- floor kick: lift the pair by one row
    local ny = (p.y // SUB + 1) * SUB
    if self.kicks < R.floor_kicks and self:fits(p.x, ny, nr) then
      p.y = ny
      self.kicks = self.kicks + 1
      self:set_rotation(nr, dir)
      return true
    end
  end
  -- blocked on both sides: a quick second press flips the pair (quick turn)
  if self.quick_turn > 0 then
    self.quick_turn = 0
    local fr = (p.r + 2) % 4
    if self:fits(p.x, p.y, fr) then
      self:set_rotation(fr, 2 * dir)
      return true
    end
    local ny = (p.y // SUB + 1) * SUB
    if self:fits(p.x, ny, fr) then
      p.y = ny
      self:set_rotation(fr, 2 * dir)
      return true
    end
  else
    self.quick_turn = R.quick_turn
  end
  return false
end

function Player:add_drop_points(n)
  if n > 0 then
    self.score = self.score + n
    self.leftover = self.leftover + n
  end
end

function Player:hard_drop()
  local p = self.piece
  local y = (p.y // SUB) * SUB
  local rows = 0
  while self:fits(p.x, y - SUB, p.r) do
    y = y - SUB
    rows = rows + 1
  end
  p.y = y
  self:add_drop_points(rows * 2)
  self:emit("hard_drop", { rows = rows })
  self:lock()
end

function Player:update_das(mask)
  local R = self.match.R
  local l, r = mask & B_LEFT ~= 0, mask & B_RIGHT ~= 0
  local dir = 0
  if l and not r then dir = -1 elseif r and not l then dir = 1 end
  if dir == 0 then
    self.das_dir, self.das_t = 0, 0
    return 0
  end
  if dir ~= self.das_dir then
    self.das_dir, self.das_t = dir, 0
    return dir
  end
  self.das_t = self.das_t + 1
  if self.das_t >= R.das and (self.das_t - R.das) % R.arr == 0 then return dir end
  return 0
end

function Player:update_move(mask, pressed, shift)
  local p = self.piece
  local R = self.match.R
  if self.quick_turn > 0 then self.quick_turn = self.quick_turn - 1 end
  local hard = self.hard_drop_enabled and R.hard_drop

  if pressed & B_ROTR ~= 0 then self:rotate(1) end
  if pressed & B_ROTL ~= 0 then self:rotate(-1) end
  if pressed & B_UP ~= 0 and not hard then self:rotate(1) end
  if shift ~= 0 then self:shift(shift) end
  if pressed & B_UP ~= 0 and hard then
    self:hard_drop()
    return
  end

  local soft = mask & B_DOWN ~= 0
  local speed = soft and R.soft_drop or self.match.gravity
  local ny = p.y - speed
  if self:fits(p.x, ny, p.r) then
    if soft then self:add_drop_points(p.y // SUB - ny // SUB) end
    p.y = ny
    self.grounded = false
    self.lock_timer = 0
  else
    if not self.grounded then self:emit("touch") end
    p.y = (p.y // SUB) * SUB
    self.grounded = true
  end

  if self.grounded then
    self.lock_timer = self.lock_timer + 1
    if soft or self.lock_timer >= R.lock_delay then self:lock() end
  end
end

------------------------------------------------------------------------
-- locking, falling, chains
------------------------------------------------------------------------

function Player:set_fall(i, off, vel, delay)
  self.aoff[i], self.avel[i], self.adelay[i] = off, vel or 0, delay or 0
end

function Player:lock()
  local p = self.piece
  self.piece = nil
  local b = self.board
  local sx, sy = p.x + RDX[p.r], p.y + RDY[p.r] * SUB
  -- place the lower puyo first so a vertical pair stacks correctly
  local order = { { p.x, p.y, p.c1 }, { sx, sy, p.c2 } }
  if sy < p.y then order[1], order[2] = order[2], order[1] end
  for k = 1, 2 do
    local x, vy, color = order[k][1], order[k][2], order[k][3]
    local y = b:drop(x, color)
    if y then
      local off = vy - y * SUB
      if off > 0 then self:set_fall(idx(x, y), off, 102, 0) end
    end
  end
  self.pieces = self.pieces + 1
  self.chain = 0
  self.state = "fall"
  self:emit("lock", { x = p.x, r = p.r })
end

-- advance the falling animation; returns true when everything has landed
function Player:update_fall()
  local R = self.match.R
  local aoff, avel, adelay = self.aoff, self.avel, self.adelay
  local busy, landed = false, false
  for i = 1, N do
    local off = aoff[i]
    if off > 0 then
      if adelay[i] > 0 then
        adelay[i] = adelay[i] - 1
        busy = true
      else
        local v = avel[i] + R.fall_accel
        if v > R.fall_max then v = R.fall_max end
        off = off - v
        if off <= 0 then
          aoff[i], avel[i] = 0, 0
          landed = true
          self:emit("landed_cell", { i = i })
        else
          aoff[i], avel[i] = off, v
          busy = true
        end
      end
    end
  end
  if landed then self:emit("land") end
  return not busy
end

function Player:check_chain()
  local m = self.match
  local R = m.R
  local b = self.board
  local groups = b:find_groups(R.pop)
  if groups then
    self.chain = self.chain + 1
    self.chaining = true
    local puyos, ncolors, sizes = Board.link_stats(groups)
    local score, bonus = Rules.link_score(R, self.chain, puyos, ncolors, sizes)
    local extra = 0
    if self.all_clear then
      self.all_clear = false
      extra = R.all_clear_garbage
      self.score = self.score + R.all_clear_score
    end
    local total = score + self.leftover
    local tp = m.target_points
    local link = {
      chain = self.chain, score = score, bonus = bonus, puyos = puyos, colors = ncolors,
      garbage = total // tp + extra, leftover = total % tp, all_clear = extra > 0,
    }
    local mod = m:hook("link", self, link)
    if type(mod) == "table" then link = mod end
    local lscore = toint(link.score, score)
    local lgarbage = math.max(0, toint(link.garbage, 0))
    self.score = self.score + lscore
    self.leftover = math.max(0, toint(link.leftover, 0))
    self.pop = { groups = groups, garbage = b:adjacent_garbage(groups), t = 0 }
    self.state = "pop"
    self:emit("pop", { chain = self.chain, score = lscore, puyos = puyos, bonus = toint(link.bonus, bonus),
                       groups = groups, garbage = lgarbage })
    m:attack(self, lgarbage)
  else
    if self.chain > 0 then
      self.max_chain = math.max(self.max_chain, self.chain)
      self.chains = self.chains + 1
      m:hook("chain_end", self, self.chain)
      self:emit("chain_end", { chain = self.chain })
      if b:is_empty() then
        self.all_clear = true
        self:emit("all_clear")
      end
    end
    self.chain = 0
    self.chaining = false
    self:receive_garbage()
  end
end

function Player:update_pop()
  local pop = self.pop
  pop.t = pop.t + 1
  if pop.t < self.match.R.pop_time then return end
  local cleared = self.board:clear(pop.groups, pop.garbage)
  self.pop = nil
  self:emit("burst", { cleared = cleared })
  local moves = self.board:gravity({})
  for k = 1, #moves do
    local mv = moves[k]
    self:set_fall(idx(mv.x, mv.to), (mv.from - mv.to) * SUB, 0, 0)
  end
  self.state = "fall"
end

------------------------------------------------------------------------
-- nuisance
------------------------------------------------------------------------

-- Nuisance falls once our chain is over, but only after the attacker has
-- finished chaining (their chain can still grow and we may still offset).
function Player:receive_garbage()
  local opp = self.opponent
  local R = self.match.R
  if self.pending > 0 and not (opp and opp.chaining) then
    local n = math.min(self.pending, R.max_drop)
    self.pending = self.pending - n
    n = math.max(0, toint(self.match:hook("garbage", self, n), n))
    if n > 0 then
      self:drop_garbage(n)
      self.state = "garbage"
      self:emit("garbage", { n = n })
      return
    end
  end
  self:prepare_spawn()
end

function Player:drop_garbage(n)
  local b = self.board
  local rows, rem = n // W, n % W
  local extra = {}
  if rem > 0 then
    local cols = self.rng:shuffle({ 1, 2, 3, 4, 5, 6 })
    for k = 1, rem do extra[cols[k]] = true end
  end
  for x = 1, W do
    local count = rows + (extra[x] and 1 or 0)
    local h = b:height(x)
    local jitter = self.rng:int(0, 800)
    local delay = self.rng:int(0, 5)
    for k = 1, count do
      local y = h + k
      if y > H then break end
      b:set(x, y, GARBAGE)
      local start = (VIS + k) * SUB + (k - 1) * 50 + jitter
      self:set_fall(idx(x, y), math.max(64, start - y * SUB), 0, delay)
    end
  end
end

------------------------------------------------------------------------
-- spawning / dying
------------------------------------------------------------------------

function Player:prepare_spawn()
  local R = self.match.R
  if self.board:get(R.death_x, R.death_y) ~= 0 then
    self.dead = true
    self.state = "dead"
    self:emit("die")
    return
  end
  self.state = "spawn_wait"
  self.timer = R.spawn_delay
end

function Player:spawn()
  local m = self.match
  self.seq_i = self.seq_i + 1
  local pair = m.seq:get(self.seq_i)
  local c1, c2 = pair[1], pair[2]
  local mod = m:hook("pair", self, { c1, c2 })
  if type(mod) == "table" then
    c1 = toint(mod[1], c1)
    c2 = toint(mod[2], c2)
    if c1 < 1 or c1 > 5 then c1 = pair[1] end
    if c2 < 1 or c2 > 5 then c2 = pair[2] end
  end
  self.piece = { x = m.R.spawn_x, y = Rules.VISIBLE * SUB, r = 0, c1 = c1, c2 = c2, ang = 0, tang = 0 }
  self.lock_timer, self.lock_resets, self.kicks, self.quick_turn = 0, 0, 0, 0
  self.grounded = false
  self.state = "move"
  self:emit("spawn")
end

------------------------------------------------------------------------
-- per-frame update (mask = held buttons this frame)
------------------------------------------------------------------------

function Player:update(mask)
  mask = mask or 0
  local pressed = mask & ~self.prev_mask
  self.prev_mask = mask
  self.frame = self.frame + 1
  local shift = self:update_das(mask)
  local st = self.state
  if st == "move" then
    self:update_move(mask, pressed, shift)
  elseif st == "fall" then
    if self:update_fall() then self:check_chain() end
  elseif st == "pop" then
    self:update_pop()
  elseif st == "garbage" then
    if self:update_fall() then self:prepare_spawn() end
  elseif st == "spawn_wait" then
    self.timer = self.timer - 1
    if self.timer <= 0 then self:spawn() end
  end
  local p = self.piece
  if p then p.ang = p.ang + (p.tang - p.ang) * 0.45 end -- visual easing only
end

------------------------------------------------------------------------
-- snapshots (rollback) and hashing (desync detection)
------------------------------------------------------------------------

local SCALARS = {
  "seq_i", "state", "timer", "frame", "score", "chain", "max_chain", "chaining", "pending",
  "leftover", "all_clear", "dead", "das_dir", "das_t", "lock_timer", "lock_resets", "kicks",
  "quick_turn", "grounded", "prev_mask", "hard_drop_enabled", "pieces", "sent", "chains",
}

function Player:save()
  local s = {}
  for i = 1, #SCALARS do
    local k = SCALARS[i]
    s[k] = self[k]
  end
  s.c = table.move(self.board.c, 1, N, 1, {})
  s.aoff = table.move(self.aoff, 1, N, 1, {})
  s.avel = table.move(self.avel, 1, N, 1, {})
  s.adelay = table.move(self.adelay, 1, N, 1, {})
  s.rng = self.rng.s
  local p = self.piece
  if p then s.piece = { p.x, p.y, p.r, p.c1, p.c2, p.ang, p.tang } end
  -- groups/garbage lists are never mutated after creation: share them
  if self.pop then s.pop = { self.pop.groups, self.pop.garbage, self.pop.t } end
  return s
end

function Player:load(s)
  for i = 1, #SCALARS do
    local k = SCALARS[i]
    self[k] = s[k]
  end
  table.move(s.c, 1, N, 1, self.board.c)
  table.move(s.aoff, 1, N, 1, self.aoff)
  table.move(s.avel, 1, N, 1, self.avel)
  table.move(s.adelay, 1, N, 1, self.adelay)
  self.rng.s = s.rng
  local p = s.piece
  self.piece = p and { x = p[1], y = p[2], r = p[3], c1 = p[4], c2 = p[5], ang = p[6], tang = p[7] } or nil
  self.pop = s.pop and { groups = s.pop[1], garbage = s.pop[2], t = s.pop[3] } or nil
end

local STATE_ID = { wait = 1, spawn_wait = 2, move = 3, fall = 4, pop = 5, garbage = 6, dead = 7 }

local function mix(h, v)
  return ((h ~ (v & 0xffffffff)) * 16777619) & 0xffffffff
end
Player.mix = mix

function Player:hash(h)
  local c, aoff = self.board.c, self.aoff
  for i = 1, N do
    h = mix(h, c[i])
    h = mix(h, aoff[i])
  end
  h = mix(h, self.score)
  h = mix(h, self.pending)
  h = mix(h, self.leftover)
  h = mix(h, self.chain)
  h = mix(h, self.seq_i)
  h = mix(h, self.rng.s)
  h = mix(h, self.timer)
  h = mix(h, STATE_ID[self.state] or 0)
  local p = self.piece
  if p then
    h = mix(h, p.x)
    h = mix(h, p.y)
    h = mix(h, p.r)
  end
  return h
end

return Player
