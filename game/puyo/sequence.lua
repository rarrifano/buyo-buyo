-- The shared pair sequence. Both players draw from the same seeded list
-- (as in Tsu), each at their own pace.
-- SPDX-License-Identifier: GPL-2.0-or-later
local U = require "core.util"

local Sequence = {}
Sequence.__index = Sequence

function Sequence.new(seed, ncolors)
  local s = setmetatable({ rng = U.rng(seed), ncolors = ncolors, list = {} }, Sequence)
  -- pick which of the 5 colors are used this round
  local all = s.rng:shuffle({ 1, 2, 3, 4, 5 })
  s.palette = {}
  for i = 1, ncolors do s.palette[i] = all[i] end
  s:refill()
  -- the first two pairs only use three colors, for gentler openings
  for n = 1, 2 do
    s.list[n] = { s.palette[s.rng:int(1, 3)], s.palette[s.rng:int(1, 3)] }
  end
  return s
end

-- a shuffled bag with the same amount of every color keeps things fair
function Sequence:refill()
  local bag = {}
  for _, c in ipairs(self.palette) do
    for _ = 1, 16 do bag[#bag + 1] = c end
  end
  self.rng:shuffle(bag)
  for i = 1, #bag, 2 do
    self.list[#self.list + 1] = { bag[i], bag[i + 1] }
  end
end

-- pair n = { pivot color, satellite color }
function Sequence:get(n)
  while #self.list < n do self:refill() end
  return self.list[n]
end

-- Rollback support: generated pairs never change, so a snapshot only needs
-- the RNG state and how many pairs existed; restoring truncates the list.
function Sequence:save() return { s = self.rng.s, n = #self.list } end

function Sequence:load(st)
  self.rng.s = st.s
  for i = #self.list, st.n + 1, -1 do self.list[i] = nil end
end

return Sequence
