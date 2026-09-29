-- Compact, safe binary serialization for plain data sent over the network.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Supports nil, booleans, integers, floats, strings and tables (nested).
-- Decoding never runs code and enforces size / depth limits, since the data
-- comes from another machine.
local Pack = {}

local MAX_DEPTH, MAX_ITEMS, MAX_STR = 8, 512, 4096

local function enc(v, out, depth)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "n"
  elseif t == "boolean" then out[#out + 1] = v and "t" or "f"
  elseif t == "number" then
    if math.type(v) == "integer" then out[#out + 1] = "i" .. string.pack("<i8", v)
    else out[#out + 1] = "d" .. string.pack("<d", v) end
  elseif t == "string" then
    out[#out + 1] = "s" .. string.pack("<s2", v:sub(1, MAX_STR))
  elseif t == "table" then
    if depth >= MAX_DEPTH then error("pack: table too deep") end
    local keys = {}
    for k in pairs(v) do
      local kt = type(k)
      if kt == "string" or kt == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    out[#out + 1] = "T" .. string.pack("<I2", #keys)
    for _, k in ipairs(keys) do
      enc(k, out, depth + 1)
      enc(v[k], out, depth + 1)
    end
  else
    out[#out + 1] = "n" -- functions etc. are dropped
  end
end

function Pack.encode(v)
  local out = {}
  enc(v, out, 0)
  return table.concat(out)
end

local function dec(s, pos, depth, budget)
  budget.n = budget.n + 1
  if budget.n > MAX_ITEMS then error("pack: too many items") end
  local tag = s:sub(pos, pos)
  pos = pos + 1
  if tag == "n" then return nil, pos
  elseif tag == "t" then return true, pos
  elseif tag == "f" then return false, pos
  elseif tag == "i" then return string.unpack("<i8", s, pos)
  elseif tag == "d" then
    local v, p = string.unpack("<d", s, pos)
    if v ~= v then v = 0 end
    return v, p
  elseif tag == "s" then return string.unpack("<s2", s, pos)
  elseif tag == "T" then
    if depth >= MAX_DEPTH then error("pack: too deep") end
    local n
    n, pos = string.unpack("<I2", s, pos)
    local t = {}
    for _ = 1, n do
      local k, v
      k, pos = dec(s, pos, depth + 1, budget)
      v, pos = dec(s, pos, depth + 1, budget)
      if k ~= nil and (type(k) == "string" or type(k) == "number") then t[k] = v end
    end
    return t, pos
  end
  error("pack: bad tag")
end

-- returns value or nil, err
function Pack.decode(s, pos)
  local ok, v = pcall(dec, s, pos or 1, 0, { n = 0 })
  if not ok then return nil, v end
  return v
end

return Pack
