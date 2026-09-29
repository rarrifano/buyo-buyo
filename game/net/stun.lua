-- Minimal STUN (RFC 5389) binding request: asks a public STUN server which
-- public address:port our UDP socket appears as, so players behind NAT can
-- share a connection code. STUN servers only echo your address; they never
-- see game traffic. Without STUN you can still play on LAN, via a VPN
-- (Tailscale, ZeroTier, ...) or with a forwarded port.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Stun = {}

Stun.SERVERS = {
  { "stun.l.google.com", 19302 },
  { "stun1.l.google.com", 19302 },
  { "stun.cloudflare.com", 3478 },
}

local MAGIC = 0x2112A442

function Stun.new_txid()
  local t = {}
  for i = 1, 12 do
    t[i] = string.char(math.random(0, 255))
  end
  return table.concat(t)
end

function Stun.request(txid) return string.pack(">I2I2I4", 0x0001, 0, MAGIC) .. txid end

function Stun.is_response(data) return #data >= 20 and data:byte(1) == 0x01 and data:byte(2) == 0x01 end

-- -> ip, port | nil
function Stun.parse(data, txid)
  if not Stun.is_response(data) then return nil end
  local _, len, magic = string.unpack(">I2I2I4", data)
  if magic ~= MAGIC or data:sub(9, 20) ~= txid then return nil end
  local pos, stop = 21, math.min(#data, 20 + len)
  local mapped_ip, mapped_port
  while pos + 3 <= stop do
    local atype, alen = string.unpack(">I2I2", data, pos)
    local val = data:sub(pos + 4, pos + 3 + alen)
    if (atype == 0x0020 or atype == 0x0001) and #val >= 8 and val:byte(2) == 1 then
      local port, addr = string.unpack(">I2I4", val, 3)
      if atype == 0x0020 then
        port = port ~ (MAGIC >> 16)
        addr = addr ~ MAGIC
      end
      local ip = string.format(
        "%d.%d.%d.%d",
        (addr >> 24) & 255,
        (addr >> 16) & 255,
        (addr >> 8) & 255,
        addr & 255
      )
      if atype == 0x0020 then return ip, port end
      mapped_ip, mapped_port = ip, port
    end
    pos = pos + 4 + alen + ((4 - alen % 4) % 4)
  end
  return mapped_ip, mapped_port
end

return Stun
