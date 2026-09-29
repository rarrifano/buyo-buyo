-- Small helpers shared by every module.
local U = {}

function U.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

function U.lerp(a, b, t) return a + (b - a) * t end

function U.approach(v, target, step)
  if v < target then return math.min(v + step, target) end
  return math.max(v - step, target)
end

function U.ease_out_cubic(t) t = 1 - t; return 1 - t * t * t end

function U.ease_out_back(t)
  local c1 = 1.70158
  local c3 = c1 + 1
  return 1 + c3 * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
end

function U.pad_number(n, width)
  return string.format("%0" .. width .. "d", math.floor(n))
end

function U.copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- xorshift32: deterministic RNG independent from math.random, so both
-- players can share a seeded piece sequence and replays stay reproducible.
local RNG = {}
RNG.__index = RNG

function U.rng(seed)
  local s = math.floor(seed or 1) & 0xffffffff
  if s == 0 then s = 0x6d2b79f5 end
  local r = setmetatable({ s = s }, RNG)
  for _ = 1, 8 do r:next() end
  return r
end

function RNG:next()
  local x = self.s
  x = x ~ ((x << 13) & 0xffffffff)
  x = x ~ (x >> 17)
  x = x ~ ((x << 5) & 0xffffffff)
  self.s = x
  return x
end

function RNG:int(a, b) return a + self:next() % (b - a + 1) end
function RNG:float() return self:next() / 4294967296.0 end

function RNG:shuffle(t)
  for i = #t, 2, -1 do
    local j = self:int(1, i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

return U
