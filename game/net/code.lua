-- Connection codes: an IPv4 address + port packed into 10 characters
-- (Crockford base32), e.g. "3R5XC-8Q2MA". Easy to read out loud or paste.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Code = {}

local ALPHA = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

function Code.encode(ip, port)
  local a, b, c, d = (ip or ""):match "^(%d+)%.(%d+)%.(%d+)%.(%d+)$"
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 or not port or port < 1 or port > 65535 then
    return nil
  end
  local n = (a << 40) | (b << 32) | (c << 24) | (d << 16) | port
  local chars = {}
  for i = 10, 1, -1 do
    local v = n & 31
    chars[i] = ALPHA:sub(v + 1, v + 1)
    n = n >> 5
  end
  return table.concat(chars, "", 1, 5) .. "-" .. table.concat(chars, "", 6, 10)
end

function Code.decode(code)
  local s = (code or ""):upper():gsub("[%s%-]", ""):gsub("O", "0"):gsub("[IL]", "1")
  if #s ~= 10 then return nil end
  local n = 0
  for i = 1, 10 do
    local p = ALPHA:find(s:sub(i, i), 1, true)
    if not p then return nil end
    n = (n << 5) | (p - 1)
  end
  local port = n & 0xffff
  local ip =
    string.format("%d.%d.%d.%d", (n >> 40) & 255, (n >> 32) & 255, (n >> 24) & 255, (n >> 16) & 255)
  if port == 0 then return nil end
  return ip, port
end

-- Parse what the user typed: a code, "1.2.3.4:7777" or "host.name:7777".
-- Returns ip, port | host, port, "resolve" | nil
function Code.parse(text, default_port)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local ip, port = Code.decode(text)
  if ip then return ip, port end
  local h, p = text:match "^([%w%.%-]+):(%d+)$"
  if not h then
    h, p = text:match "^([%w%.%-]+)$", default_port
  end
  if not h or h == "" then return nil end
  p = tonumber(p)
  if not p or p < 1 or p > 65535 then return nil end
  if h:match "^%d+%.%d+%.%d+%.%d+$" then return h, p end
  return h, p, "resolve"
end

return Code
