-- The playfield: a flat array of 6 x 13 cells, row-major from the bottom.
-- Cell values: 0 empty, 1..5 colors, Rules.GARBAGE nuisance.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Rules = require "puyo.rules"

local W, H, VIS = Rules.COLS, Rules.ROWS, Rules.VISIBLE
local GARBAGE = Rules.GARBAGE
local N = W * H

local Board = {}
Board.__index = Board
Board.W, Board.H, Board.VIS, Board.N = W, H, VIS, N

local function idx(x, y) return (y - 1) * W + x end
Board.idx = idx

function Board.xy(i)
  local y = (i - 1) // W + 1
  return i - (y - 1) * W, y
end

-- orthogonal neighbours restricted to the visible rows (used for popping)
local NEIGH = {}
for y = 1, VIS do
  for x = 1, W do
    local t = {}
    if x > 1 then t[#t + 1] = idx(x - 1, y) end
    if x < W then t[#t + 1] = idx(x + 1, y) end
    if y > 1 then t[#t + 1] = idx(x, y - 1) end
    if y < VIS then t[#t + 1] = idx(x, y + 1) end
    NEIGH[idx(x, y)] = t
  end
end
Board.NEIGH = NEIGH

function Board.new()
  local c = {}
  for i = 1, N do
    c[i] = 0
  end
  return setmetatable({ c = c }, Board)
end

function Board:clone() return setmetatable({ c = table.move(self.c, 1, N, 1, {}) }, Board) end

function Board:get(x, y)
  if x < 1 or x > W or y < 1 or y > H then return nil end
  return self.c[idx(x, y)]
end

function Board:set(x, y, v) self.c[idx(x, y)] = v end

function Board:height(x)
  local c = self.c
  for y = H, 1, -1 do
    if c[idx(x, y)] ~= 0 then return y end
  end
  return 0
end

function Board:is_empty()
  local c = self.c
  for i = 1, N do
    if c[i] ~= 0 then return false end
  end
  return true
end

-- Drop one puyo on top of column x. Returns the row, or nil when the column
-- is full (the puyo vanishes above the field, like the 14th row in Tsu).
function Board:drop(x, v)
  local h = self:height(x)
  if h >= H then return nil end
  self.c[idx(x, h + 1)] = v
  return h + 1
end

-- Compact all columns. If `moves` is given, appends {x=, from=, to=} records.
function Board:gravity(moves)
  local c = self.c
  for x = 1, W do
    local w = 1
    for y = 1, H do
      local i = idx(x, y)
      local v = c[i]
      if v ~= 0 then
        if y ~= w then
          c[idx(x, w)] = v
          c[i] = 0
          if moves then moves[#moves + 1] = { x = x, from = y, to = w } end
        end
        w = w + 1
      end
    end
  end
  return moves
end

local mark, stamp = {}, 0
for i = 1, N do
  mark[i] = 0
end

-- Groups of >= `pop` same-colored puyos inside the visible rows.
-- Returns nil or a list of { color = c, cells = { idx, ... } }.
function Board:find_groups(pop)
  pop = pop or 4
  local c = self.c
  stamp = stamp + 1
  local groups
  for i = 1, W * VIS do
    local v = c[i]
    if v >= 1 and v <= 5 and mark[i] ~= stamp then
      local cells = { i }
      mark[i] = stamp
      local head = 1
      while head <= #cells do
        local nb = NEIGH[cells[head]]
        head = head + 1
        for k = 1, #nb do
          local n = nb[k]
          if mark[n] ~= stamp and c[n] == v then
            mark[n] = stamp
            cells[#cells + 1] = n
          end
        end
      end
      if #cells >= pop then
        groups = groups or {}
        groups[#groups + 1] = { color = v, cells = cells }
      end
    end
  end
  return groups
end

-- Nuisance puyos touching any popping cell (visible rows only).
function Board:adjacent_garbage(groups)
  local c, seen, list = self.c, {}, {}
  for _, g in ipairs(groups) do
    for _, i in ipairs(g.cells) do
      for _, n in ipairs(NEIGH[i]) do
        if c[n] == GARBAGE and not seen[n] then
          seen[n] = true
          list[#list + 1] = n
        end
      end
    end
  end
  return list
end

-- Link statistics for scoring: cleared colored puyos, colors, group sizes.
function Board.link_stats(groups)
  local puyos, ncolors, sizes, seen = 0, 0, {}, {}
  for _, g in ipairs(groups) do
    puyos = puyos + #g.cells
    sizes[#sizes + 1] = #g.cells
    if not seen[g.color] then
      seen[g.color] = true
      ncolors = ncolors + 1
    end
  end
  return puyos, ncolors, sizes
end

-- Remove the groups and the nuisance next to them.
-- Returns a list of { i = idx, v = value } for effects.
function Board:clear(groups, garbage)
  local c, out = self.c, {}
  for _, g in ipairs(groups) do
    for _, i in ipairs(g.cells) do
      if c[i] ~= 0 then
        out[#out + 1] = { i = i, v = c[i] }
        c[i] = 0
      end
    end
  end
  for _, i in ipairs(garbage or self:adjacent_garbage(groups)) do
    if c[i] ~= 0 then
      out[#out + 1] = { i = i, v = c[i] }
      c[i] = 0
    end
  end
  return out
end

-- Resolve every chain link instantly. Returns chain count and total score.
function Board:resolve(R)
  R = R or Rules.make()
  local chain, score = 0, 0
  while true do
    local groups = self:find_groups(R.pop)
    if not groups then break end
    chain = chain + 1
    local puyos, ncolors, sizes = Board.link_stats(groups)
    score = score + Rules.link_score(R, chain, puyos, ncolors, sizes)
    self:clear(groups)
    self:gravity()
  end
  return chain, score
end

-- Build a board from rows of text, top row first. Letters: R G B Y P, O = nuisance.
-- Handy for tests.
local LETTERS = { R = 1, G = 2, B = 3, Y = 4, P = 5, O = GARBAGE }
function Board.from_rows(rows)
  local b = Board.new()
  local n = #rows
  for r, line in ipairs(rows) do
    local y = n - r + 1
    for x = 1, W do
      local ch = line:sub(x, x)
      b:set(x, y, LETTERS[ch] or 0)
    end
  end
  return b
end

return Board
