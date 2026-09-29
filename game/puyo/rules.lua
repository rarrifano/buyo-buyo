-- Game rules: the defaults every mode starts from.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- IMPORTANT: everything that feeds the simulation is an integer (positions
-- use fixed point, see SUB) so matches are bit-for-bit deterministic on every
-- platform. Rollback netplay depends on this.
--
-- Board coordinates: x = 1..6 (left to right), y = 1..13 (bottom to top).
-- Row 13 is the hidden row: puyos can rest there but never pop.
local Rules = {}

Rules.SUB = 1024                 -- sub-row units per row (falling positions)
Rules.COLS, Rules.ROWS, Rules.VISIBLE = 6, 13, 12
Rules.GARBAGE = 6                -- cell value of nuisance puyos (colors are 1..5)

-- Every key here can be overridden by a mode (mode.rules = { ... }).
Rules.DEFAULTS = {
  colors = 4,                    -- colors in play (3..5)
  pop = 4,                       -- group size that pops (2..8)
  spawn_x = 3,                   -- column where pairs appear
  death_x = 3, death_y = 12,     -- the "X": filled at spawn time = you lose
  target_points = 70,            -- score points per nuisance puyo
  max_drop = 30,                 -- nuisance falling at once (5 rows)
  all_clear_garbage = 30,
  all_clear_score = 2100,
  margin_time = 96 * 60,         -- frames until nuisance starts getting cheaper
  margin_step = 16 * 60,         -- every step: target points * 3/4
  das = 9, arr = 2,              -- auto-shift delay / repeat (frames)
  gravity = 28,                  -- sub-rows per frame (1024 = one row)
  soft_drop = 512,
  lock_delay = 30,
  lock_resets = 10,
  floor_kicks = 8,
  quick_turn = 18,               -- double-tap window for the 180 degree flip
  pop_time = 42,                 -- frames a popping group flashes
  fall_accel = 46,               -- falling animation (sub-rows / frame^2)
  fall_max = 922,
  spawn_delay = 8,
  ready_time = 150,              -- READY? GO! countdown
  over_time = 220,               -- pause after a round
  first_to = 2,                  -- round wins needed
  hard_drop = true,              -- allow hard drop at all
  chain_power = { 0, 8, 16, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 480, 512 },
  color_bonus = { 0, 3, 6, 12, 24 },
  group_bonus = { [4] = 0, [5] = 2, [6] = 3, [7] = 4, [8] = 5, [9] = 6, [10] = 7, [11] = 10 },
}

local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = copy(x) end
  return t
end
Rules.copy = copy

local function int(v, lo, hi)
  v = math.tointeger(math.floor(v)) or lo
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end

-- Build a rules table: defaults <- each override table in order.
-- Numbers are forced to sane integer ranges so a broken mode cannot crash
-- the engine (and floats can never leak into the simulation).
function Rules.make(...)
  local R = copy(Rules.DEFAULTS)
  for i = 1, select("#", ...) do
    local o = select(i, ...)
    if type(o) == "table" then
      for k, v in pairs(o) do
        if Rules.DEFAULTS[k] ~= nil and type(v) == type(Rules.DEFAULTS[k]) then R[k] = copy(v) end
      end
    end
  end
  R.colors = int(R.colors, 3, 5)
  R.pop = int(R.pop, 2, 12)
  R.spawn_x = int(R.spawn_x, 1, 6)
  R.death_x, R.death_y = int(R.death_x, 1, 6), int(R.death_y, 1, 12)
  R.target_points = int(R.target_points, 1, 100000)
  R.max_drop = int(R.max_drop, 1, 78)
  for _, k in ipairs { "all_clear_garbage", "all_clear_score", "margin_time", "margin_step", "das", "lock_delay",
                       "lock_resets", "floor_kicks", "quick_turn", "spawn_delay", "ready_time", "over_time" } do
    R[k] = int(R[k], 0, 1000000)
  end
  R.arr = int(R.arr, 1, 60)
  R.margin_step = math.max(1, R.margin_step)
  R.gravity = int(R.gravity, 1, Rules.SUB - 1)
  R.soft_drop = int(R.soft_drop, 1, Rules.SUB - 1)
  R.pop_time = int(R.pop_time, 1, 600)
  R.fall_accel = int(R.fall_accel, 1, Rules.SUB)
  R.fall_max = int(R.fall_max, 1, Rules.SUB * 4)
  R.first_to = int(R.first_to, 1, 99)
  -- lookup tables for the hot paths
  local cp = {}
  for n = 1, 100 do
    local t = R.chain_power
    cp[n] = n <= #t and int(t[n], 0, 999) or math.min(999, int(t[#t] or 0, 0, 999) + (n - #t) * 32)
  end
  R.cp = cp
  local gb, best = {}, 0
  for s = 1, 78 do
    if R.group_bonus[s] then best = int(R.group_bonus[s], 0, 999) end
    gb[s] = s < R.pop and 0 or best
  end
  R.gb = gb
  local cb = {}
  for n = 1, 5 do cb[n] = int(R.color_bonus[n] or R.color_bonus[#R.color_bonus] or 0, 0, 999) end
  R.cb = cb
  return R
end

-- score of one chain link: 10 * cleared * clamp(CP + CB + GB, 1, 999)
function Rules.link_score(R, chain, puyos, ncolors, sizes)
  local bonus = R.cp[math.min(chain, 100)] + R.cb[math.min(ncolors, 5)]
  for i = 1, #sizes do bonus = bonus + R.gb[math.min(sizes[i], 78)] end
  if bonus < 1 then bonus = 1 elseif bonus > 999 then bonus = 999 end
  return 10 * puyos * bonus, bonus
end

-- margin time: after it expires nuisance gets cheaper (integer math only)
function Rules.target_points(R, frames)
  local tp = R.target_points
  if frames < R.margin_time then return tp end
  local steps = (frames - R.margin_time) // R.margin_step + 1
  for _ = 1, math.min(steps, 64) do tp = math.max(1, tp * 3 // 4) end
  return tp
end

return Rules
