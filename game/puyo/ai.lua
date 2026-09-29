-- CPU opponent.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- For every reachable placement of the current pair the AI simulates the
-- drop and any chain it triggers, then scores the resulting field:
--   * connectivity of same colors and a penalty for dangerous heights,
--   * "virtual chain" potential: the longest chain that 1-2 extra puyos of a
--     neighbouring color could set off (this is what makes it build chains),
--   * a firing policy: fire when the chain is big enough for the level, to
--     counter incoming nuisance, to finish a weak opponent, or when in danger.
-- Stronger levels also look one pair ahead. The search runs in a coroutine
-- with a per-frame time budget. The plan is executed by producing the same
-- button bitmask a human controller would, one frame at a time.
--
-- Characters can tweak it with a `cpu` table (see docs/CHARACTERS.md):
--   cpu = { chain_goal = 1, speed = 1.2, noise = 0.5 }
local Rules = require "puyo.rules"
local Player = require "puyo.player"
local U = require "core.util"

local W, H, VIS = Rules.COLS, Rules.ROWS, Rules.VISIBLE
local N = W * H
local GARBAGE = Rules.GARBAGE
local BUDGET = 0.003 -- seconds of search per frame
local BTN = Player.BUTTONS

local AI = {}
AI.__index = AI

AI.LEVELS = {
  { name = "EASY",   think = 50, interval = 14, soft = 0.0, noise = 700, potential = false,
    lookahead = false, fire_chain = 1, fire_garbage = 0,  mistake = 0.30 },
  { name = "NORMAL", think = 26, interval = 7,  soft = 0.35, noise = 160, potential = true,
    lookahead = false, fire_chain = 3, fire_garbage = 12, mistake = 0.05 },
  { name = "HARD",   think = 12, interval = 4,  soft = 1.0, noise = 40,  potential = true,
    lookahead = true,  fire_chain = 5, fire_garbage = 24, mistake = 0 },
  { name = "MANIAC", think = 5,  interval = 2,  soft = 1.0, noise = 0,   potential = true,
    lookahead = true,  fire_chain = 7, fire_garbage = 40, mistake = 0, hard_drop = true },
}

------------------------------------------------------------------------
-- fast field simulation on flat arrays
------------------------------------------------------------------------

local NB = {}
for y = 1, VIS do
  for x = 1, W do
    local i, t = (y - 1) * W + x, {}
    if x > 1 then t[#t + 1] = i - 1 end
    if x < W then t[#t + 1] = i + 1 end
    if y > 1 then t[#t + 1] = i - W end
    if y < VIS then t[#t + 1] = i + W end
    NB[i] = t
  end
end

local mark, stamp = {}, 0
for i = 1, N do mark[i] = 0 end
local queue, popped = {}, {}

-- resolves all chains in place under rules R; returns chain length and score
local function simulate(c, R)
  local pop, CPT, CBT, GBT = R.pop, R.cp, R.cb, R.gb
  local chain, score = 0, 0
  while true do
    stamp = stamp + 1
    local npop, gb, colmask, ncol = 0, 0, 0, 0
    for i = 1, W * VIS do
      local v = c[i]
      if v ~= 0 and v ~= GARBAGE and mark[i] ~= stamp then
        mark[i] = stamp
        queue[1] = i
        local qh, qt = 1, 1
        while qh <= qt do
          local nb = NB[queue[qh]]
          qh = qh + 1
          for k = 1, #nb do
            local n = nb[k]
            if mark[n] ~= stamp and c[n] == v then
              mark[n] = stamp
              qt = qt + 1
              queue[qt] = n
            end
          end
        end
        if qt >= pop then
          for k = 1, qt do popped[npop + k] = queue[k] end
          npop = npop + qt
          gb = gb + GBT[qt]
          local bit = 1 << v
          if colmask & bit == 0 then
            colmask = colmask | bit
            ncol = ncol + 1
          end
        end
      end
    end
    if npop == 0 then break end
    chain = chain + 1
    local bonus = CPT[math.min(chain, 100)] + CBT[ncol] + gb
    if bonus < 1 then bonus = 1 elseif bonus > 999 then bonus = 999 end
    score = score + 10 * npop * bonus
    for k = 1, npop do c[popped[k]] = 0 end
    for k = 1, npop do
      local nb = NB[popped[k]]
      for q = 1, #nb do
        local n = nb[q]
        if c[n] == GARBAGE then c[n] = 0 end
      end
    end
    for x = 1, W do
      local w = x
      for i = x, N, W do
        local v = c[i]
        if v ~= 0 then
          if i ~= w then
            c[w] = v
            c[i] = 0
          end
          w = w + W
        end
      end
    end
  end
  return chain, score
end
AI.simulate = simulate

local function height(c, x)
  for i = (H - 1) * W + x, 1, -W do
    if c[i] ~= 0 then return (i - x) // W + 1 end
  end
  return 0
end

local function drop(c, x, v)
  local h = height(c, x)
  if h >= H then return false end
  c[h * W + x] = v
  return true
end

local PLACEMENTS = {}
for x = 1, W do
  PLACEMENTS[#PLACEMENTS + 1] = { x = x, r = 0 }
  PLACEMENTS[#PLACEMENTS + 1] = { x = x, r = 2 }
end
for x = 1, W - 1 do PLACEMENTS[#PLACEMENTS + 1] = { x = x, r = 1 } end
for x = 2, W do PLACEMENTS[#PLACEMENTS + 1] = { x = x, r = 3 } end
AI.PLACEMENTS = PLACEMENTS

local function other_x(pl)
  return pl.x + (pl.r == 1 and 1 or pl.r == 3 and -1 or 0)
end

local function apply(c, pl, c1, c2)
  local ok1, ok2
  if pl.r == 2 then
    ok2 = drop(c, pl.x, c2)
    ok1 = drop(c, pl.x, c1)
  else
    ok1 = drop(c, pl.x, c1)
    ok2 = drop(c, other_x(pl), c2)
  end
  return ok1 and ok2
end

-- the pair travels at the top of the field: tall columns block the way
local function reachable(c, pl, spawn_x)
  local x2 = other_x(pl)
  local lo = math.min(spawn_x, pl.x, x2)
  local hi = math.max(spawn_x, pl.x, x2)
  for x = lo, hi do
    if height(c, x) >= VIS then return false end
  end
  return true
end

------------------------------------------------------------------------
-- evaluation
------------------------------------------------------------------------

local function evaluate(c, heights, death_x)
  local s = 0
  for x = 1, W do heights[x] = height(c, x) end
  if heights[death_x] >= VIS then return -1e7 end
  for x = 1, W do
    local h = heights[x]
    local d = math.abs(x - death_x)
    local lim = d == 0 and 8 or (d == 1 and 9 or 10)
    if h > lim then s = s - (h - lim) ^ 2 * 150 end
  end
  local conn = 0
  for y = 1, VIS do
    local base = (y - 1) * W
    for x = 1, W do
      local i = base + x
      local v = c[i]
      if v ~= 0 and v ~= GARBAGE then
        if x < W and c[i + 1] == v then conn = conn + 1 end
        if y < VIS and c[i + W] == v then conn = conn + 1 end
      end
    end
  end
  s = s + conn * 14
  for x = 1, W - 1 do
    local d = heights[x] - heights[x + 1]
    if d < 0 then d = -d end
    if d > 2 then s = s - (d - 2) * 30 end
  end
  return s
end

local scratch = {}

-- longest chain triggered by dropping 1-2 puyos of a neighbouring color
local function potential(c, heights, R)
  local best_chain, best_score = 0, 0
  for x = 1, W do
    local h = heights[x]
    if h <= VIS - 2 then
      local base = h * W + x -- landing cell (x, h + 1)
      local below = h > 0 and c[base - W] or 0
      local left = x > 1 and c[base - 1] or 0
      local right = x < W and c[base + 1] or 0
      for k = 1, 3 do
        local v = (k == 1 and below) or (k == 2 and left) or right
        local dup = (k == 2 and v == below) or (k == 3 and (v == below or v == left))
        if v ~= 0 and v ~= GARBAGE and not dup then
          for add = 1, 2 do
            table.move(c, 1, N, 1, scratch)
            scratch[base] = v
            if add == 2 then scratch[base + W] = v end
            local ch, sc = simulate(scratch, R)
            if ch > 0 then
              if ch > best_chain or (ch == best_chain and sc > best_score) then
                best_chain, best_score = ch, sc
              end
              break
            end
          end
        end
      end
    end
  end
  return best_chain, best_score
end

------------------------------------------------------------------------
-- brain
------------------------------------------------------------------------

-- personality (optional): { chain_goal = +/-n, speed = x, noise = x }
function AI.new(level, seed, personality)
  local base = AI.LEVELS[U.clamp(level or 2, 1, #AI.LEVELS)]
  local lv = U.copy(base)
  personality = type(personality) == "table" and personality or {}
  if type(personality.chain_goal) == "number" then
    lv.fire_chain = U.clamp(lv.fire_chain + math.floor(personality.chain_goal), 1, 12)
  end
  if type(personality.speed) == "number" and personality.speed > 0 then
    lv.interval = math.max(2, math.floor(lv.interval / personality.speed + 0.5))
    lv.think = math.max(1, math.floor(lv.think / personality.speed + 0.5))
  end
  if type(personality.noise) == "number" then lv.noise = lv.noise * math.max(0, personality.noise) end
  return setmetatable({
    lv = lv, level = level, rng = U.rng(seed or 12345),
    plan_for = nil, target = nil, co = nil, wait = 0, cool = 0, tries = 0, soft = false,
  }, AI)
end

-- forget any plan in progress (new round)
function AI:reset()
  self.plan_for, self.target, self.co = nil, nil, nil
  self.wait, self.cool = 0, 0
end

local function danger_of(c, death_x)
  local hmax, hd = 0, height(c, death_x)
  for x = 1, W do hmax = math.max(hmax, height(c, x)) end
  return hd >= 9 or hmax >= 11, hd
end

function AI:value(e, ctx, heights)
  local lv = self.lv
  local v = evaluate(e.board, heights, ctx.R.death_x)
  if v <= -1e6 then return v end
  if e.lost then v = v - 800 end
  if lv.potential then
    local pc, ps = potential(e.board, heights, ctx.R)
    v = v + pc * pc * 45 + (ps / ctx.tp) * 2
  end
  if e.chain > 0 then
    local garbage = e.score / ctx.tp
    local offset = math.min(garbage, ctx.pending)
    if e.chain >= lv.fire_chain or (lv.fire_garbage > 0 and garbage >= lv.fire_garbage) then
      v = v + 5000 + garbage * 40
    elseif ctx.pending > 0 and garbage >= math.min(ctx.pending, 30) * 0.7 then
      v = v + 3000 + garbage * 40 -- counter / fully offset incoming nuisance
    elseif ctx.pending >= 12 then
      v = v + 900 + offset * 60 -- under heavy attack: cancel what we can
    elseif ctx.opp_danger and garbage >= 5 then
      v = v + 2500 + garbage * 40 -- finish them off
    elseif ctx.danger then
      v = v + 1500 + garbage * 30
    else
      v = v - 400 * e.chain - garbage * 5 -- too small: keep building
    end
  end
  return v
end

function AI:plan(player, match)
  local lv = self.lv
  local R = match.R
  local piece = player.piece
  local c0 = table.move(player.board.c, 1, N, 1, {})
  local c1, c2 = piece.c1, piece.c2
  local heights = {}
  local danger = danger_of(c0, R.death_x)
  local opp_danger = player.opponent and select(2, danger_of(player.opponent.board.c, R.death_x)) >= 10
  local ctx = { R = R, tp = match.target_points, pending = player.pending, danger = danger, opp_danger = opp_danger }
  local t0 = sys.time()

  local cands = {}
  for _, pl in ipairs(PLACEMENTS) do
    local dup = c1 == c2 and (pl.r == 2 or pl.r == 3)
    if not dup and reachable(c0, pl, R.spawn_x) then
      local c = table.move(c0, 1, N, 1, {})
      local ok = apply(c, pl, c1, c2)
      local ch, sc = simulate(c, R)
      local e = { pl = pl, board = c, chain = ch, score = sc, lost = not ok }
      e.value = self:value(e, ctx, heights) + self.rng:float() * lv.noise
      cands[#cands + 1] = e
      if sys.time() - t0 > BUDGET then
        coroutine.yield()
        t0 = sys.time()
      end
    end
  end
  if #cands == 0 then return { x = piece.x, r = piece.r } end
  table.sort(cands, function(a, b) return a.value > b.value end)

  if lv.lookahead then
    local nxt = player:next_pair(1)
    for k = 1, math.min(6, #cands) do
      local e = cands[k]
      if e.chain == 0 then
        local best = 0
        for _, pl in ipairs(PLACEMENTS) do
          if reachable(e.board, pl, R.spawn_x) then
            local c = table.move(e.board, 1, N, 1, {})
            apply(c, pl, nxt[1], nxt[2])
            local ch, sc = simulate(c, R)
            if ch >= lv.fire_chain then
              best = math.max(best, 600 + ch * 150 + (sc / ctx.tp) * 30)
            end
          end
        end
        e.value = e.value + best * 0.8
        if sys.time() - t0 > BUDGET then
          coroutine.yield()
          t0 = sys.time()
        end
      end
    end
    table.sort(cands, function(a, b) return a.value > b.value end)
  end

  local pick = cands[1]
  if lv.mistake > 0 and self.rng:float() < lv.mistake then
    pick = cands[self.rng:int(1, math.min(#cands, 6))]
  end
  return { x = pick.pl.x, r = pick.pl.r, chain = pick.chain }
end

-- this frame's button bitmask for `player`
function AI:update(player, match)
  if player.state ~= "move" or not player.piece then return 0 end
  local lv = self.lv
  if self.plan_for ~= player.seq_i then
    self.plan_for = player.seq_i
    self.target = nil
    self.co = coroutine.create(function() return self:plan(player, match) end)
    self.wait = lv.think + self.rng:int(0, lv.think // 2)
    self.cool = 0
    self.tries = 0
    self.soft = self.rng:float() < lv.soft
  end
  if self.co then
    local ok, res = coroutine.resume(self.co)
    if not ok then error(res, 0) end
    if coroutine.status(self.co) == "dead" then
      self.co = nil
      self.target = res
    end
  end
  if self.wait > 0 then self.wait = self.wait - 1 end
  if not self.target or self.wait > 0 then return 0 end
  if self.cool > 0 then
    self.cool = self.cool - 1
    return 0
  end

  local p, t = player.piece, self.target
  local mask = 0
  if p.r ~= t.r then
    mask = (t.r - p.r) % 4 == 3 and BTN.rot_l or BTN.rot_r
    self.cool = lv.interval
    self.tries = self.tries + 1
  elseif p.x ~= t.x then
    mask = p.x < t.x and BTN.right or BTN.left
    self.cool = lv.interval
    self.tries = self.tries + 1
  elseif lv.hard_drop and player.hard_drop_enabled and match.R.hard_drop then
    mask = BTN.up
    self.cool = 2
  elseif self.soft then
    mask = BTN.down
  end
  if self.tries > 16 then
    self.target = { x = p.x, r = p.r } -- the path is blocked: settle for where we are
  end
  return mask
end

return AI
