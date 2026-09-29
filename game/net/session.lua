-- Peer-to-peer session over UDP: handshake, lobby messages, match start,
-- input packets, pings and desync checks. No server involved.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Connecting: both sides send HELLO packets containing their random nonce and
-- the nonce they have seen from the other side. A side is "connected" once it
-- knows the peer has seen it too, so traffic works in both directions. When
-- both players type each other's code at about the same time this is also
-- UDP hole punching, which gets through most home routers (NATs).
-- The side with the lower nonce is the host (player 1).
--
-- Packet: "BUY" | type:u8 | sender nonce:u32 | body
local Pack = require "net.pack"
local Stun = require "net.stun"
local Code = require "net.code"
local Content = require "core.content"

local Session = {}
Session.__index = Session

Session.DEFAULT_PORT = 7777
local MAGIC = "BUY"
local PROTO = 1
local T = {
  HELLO = 1,
  LOBBY = 2,
  START = 3,
  START_ACK = 4,
  INPUT = 5,
  PING = 6,
  PONG = 7,
  CHECK = 8,
  BYE = 9,
}
Session.T = T

-- a random 31-bit id; mixes several entropy sources so two game processes
-- started at the same moment on the same machine never collide
function Session.new_nonce()
  local addr = tonumber(tostring({}):match "0x(%x+)" or "0", 16) or 0
  local t = math.floor(sys.time() * 1e6)
  local n = (math.random(0, 0x7fffffff) ~ (t * 2654435761) ~ (addr * 40503)) & 0x7fffffff
  return n == 0 and 1 or n
end

-- opts: port, name, sim = { lag = ms, jitter = ms, loss = percent } (testing)
function Session.new(opts)
  opts = opts or {}
  local sock, err = net.udp(opts.port or Session.DEFAULT_PORT)
  if not sock then
    sock, err = net.udp(0)
  end
  if not sock then return nil, err end
  local s = setmetatable({}, Session)
  s.sock = sock
  s.port = sock:port()
  s.nonce = Session.new_nonce()
  s.name = (opts.name or "player"):sub(1, 16)
  s.state = "idle" -- idle | waiting | connecting | handshake | connected | closed
  s.lan_ip = net.local_ip() or "127.0.0.1"
  s.events = {}
  s.sim = opts.sim
  s.outq = {}
  s.rtt = 0.1
  s.last_recv = sys.time()
  s.stats = { sent = 0, recv = 0, bytes_out = 0, bytes_in = 0 }
  return s
end

function Session:push(name, data) self.events[#self.events + 1] = { name = name, data = data or {} } end

-- take the queued events
function Session:poll()
  local ev = self.events
  self.events = {}
  return ev
end

function Session:is_host() return self.peer_nonce ~= nil and self.nonce < self.peer_nonce end

function Session:codes()
  return {
    lan = Code.encode(self.lan_ip, self.port),
    public = self.public and Code.encode(self.public.ip, self.public.port) or nil,
  }
end

------------------------------------------------------------------------
-- sending
------------------------------------------------------------------------

function Session:raw_send(ip, port, data)
  self.stats.sent = self.stats.sent + 1
  self.stats.bytes_out = self.stats.bytes_out + #data
  if self.sim then
    if math.random(1, 100) <= (self.sim.loss or 0) then return end
    local delay = ((self.sim.lag or 0) + math.random() * (self.sim.jitter or 0)) / 1000
    self.outq[#self.outq + 1] = { at = sys.time() + delay, ip = ip, port = port, data = data }
  else
    self.sock:send(ip, port, data)
  end
end

function Session:packet(typ, body)
  return MAGIC .. string.char(typ) .. string.pack("<I4", self.nonce) .. (body or "")
end

function Session:send(typ, body)
  if self.peer then self:raw_send(self.peer.ip, self.peer.port, self:packet(typ, body)) end
end

function Session:hello_packet()
  return self:packet(
    T.HELLO,
    string.pack(
      "<I2I4I4s1s1",
      PROTO,
      self.nonce,
      self.peer_nonce or 0,
      Content.core_hash(),
      self.name
    )
  )
end

function Session:send_lobby(tbl) self:send(T.LOBBY, Pack.encode(tbl)) end
function Session:send_start(cfg) self:send(T.START, Pack.encode(cfg)) end
function Session:send_start_ack() self:send(T.START_ACK) end
function Session:send_check(frame, sum) self:send(T.CHECK, string.pack("<I4I4", frame, sum)) end

-- inputs for frames start.. (list of masks), our ack of their inputs, our frame
function Session:send_input(start, masks, ack, frame)
  local bytes = {}
  for i = 1, #masks do
    bytes[i] = string.char(masks[i] & 0xff)
  end
  self:send(T.INPUT, string.pack("<I4I4i4I1", start, frame, ack, #masks) .. table.concat(bytes))
end

------------------------------------------------------------------------
-- connecting
------------------------------------------------------------------------

-- accept the first peer that says hello
function Session:wait()
  if self.state == "idle" then self.state = "waiting" end
end

-- actively connect (also punches our NAT towards them)
function Session:connect(ip, port)
  self.target = { ip = ip, port = port }
  if self.state == "idle" or self.state == "waiting" then self.state = "connecting" end
  self.hello_t = 0
end

function Session:set_connected()
  if self.state == "connected" then return end
  self.state = "connected"
  self:raw_send(self.peer.ip, self.peer.port, self:hello_packet())
  self:push(
    "connected",
    { host = self:is_host(), name = self.peer_name, ip = self.peer.ip, port = self.peer.port }
  )
end

function Session:close(reason)
  if self.state == "connected" or self.state == "handshake" then
    for _ = 1, 3 do
      self:send(T.BYE)
    end
    if self.sim then self:flush(math.huge) end
  end
  self.state = "closed"
  self.close_reason = reason
end

------------------------------------------------------------------------
-- STUN (public address discovery)
------------------------------------------------------------------------

function Session:start_stun(servers)
  self.stun = { t0 = sys.time(), txid = Stun.new_txid(), pending = {} }
  for _, s in ipairs(servers or Stun.SERVERS) do
    self.stun.pending[#self.stun.pending + 1] =
      { host = s[1], port = s[2], res = net.resolve(s[1]) }
  end
end

function Session:update_stun(now)
  local st = self.stun
  if not st or st.done then return end
  for _, p in ipairs(st.pending) do
    if p.res and not p.sent then
      local ip = p.res:result()
      if ip then
        p.sent = true
        self:raw_send_direct(ip, p.port, Stun.request(st.txid))
      elseif ip == false then
        p.sent = true
      end
    end
  end
  if now - st.t0 > 5 then
    st.done = true
    if not self.public then self:push("stun", { ok = false }) end
  end
end

-- STUN requests bypass the lag simulator
function Session:raw_send_direct(ip, port, data) self.sock:send(ip, port, data) end

------------------------------------------------------------------------
-- receiving
------------------------------------------------------------------------

function Session:on_packet(data, ip, port, now)
  if Stun.is_response(data) then
    if self.stun and not self.public then
      local pip, pport = Stun.parse(data, self.stun.txid)
      if pip then
        self.public = { ip = pip, port = pport }
        self.stun.done = true
        self:push("stun", { ok = true, ip = pip, port = pport })
      end
    end
    return
  end
  if #data < 8 or data:sub(1, 3) ~= MAGIC then return end
  self.stats.recv = self.stats.recv + 1
  self.stats.bytes_in = self.stats.bytes_in + #data
  local typ = data:byte(4)
  local sender = string.unpack("<I4", data, 5)

  if typ == T.HELLO then
    local ok, proto, nonce, seen, hash, name = pcall(string.unpack, "<I2I4I4s1s1", data, 9)
    if not ok then return end
    if proto ~= PROTO then
      self:push(
        "error",
        { msg = "the other player runs an incompatible version (protocol " .. proto .. ")" }
      )
      return
    end
    if self.state == "connected" then
      if nonce == self.peer_nonce and seen ~= self.nonce then
        self:raw_send(ip, port, self:hello_packet())
      end
      return
    end
    if self.state ~= "waiting" and self.state ~= "connecting" and self.state ~= "handshake" then
      return
    end
    if hash ~= Content.core_hash() then
      self:push("error", { msg = "the other player has a different game version" })
      return
    end
    if self.peer_nonce and nonce ~= self.peer_nonce then return end -- someone else
    if nonce == self.nonce then
      -- astronomically unlikely, but host/guest roles depend on nonces differing
      self.nonce = Session.new_nonce()
      return
    end
    self.peer = { ip = ip, port = port }
    self.peer_nonce = nonce
    self.peer_name = name
    self.last_recv = now
    if self.state ~= "handshake" then
      self.state = "handshake"
      self:raw_send(ip, port, self:hello_packet())
    end
    if seen == self.nonce then self:set_connected() end
    return
  end

  if sender ~= self.peer_nonce then return end -- stray / old session
  self.last_recv = now
  if self.state == "handshake" then self:set_connected() end
  if self.state ~= "connected" then return end

  if typ == T.INPUT then
    local ok, start, frame, ack, count, pos = pcall(string.unpack, "<I4I4i4I1", data, 9)
    if ok and self.on_input then
      self.on_input(start, data:sub(pos, pos + count - 1), ack, frame)
    end
  elseif typ == T.CHECK then
    local ok, frame, sum = pcall(string.unpack, "<I4I4", data, 9)
    if ok and self.on_check then self.on_check(frame, sum) end
  elseif typ == T.PING then
    self:send(T.PONG, data:sub(9, 16))
  elseif typ == T.PONG then
    local ok, t = pcall(string.unpack, "<d", data, 9)
    if ok then
      local sample = math.max(0, now - t)
      self.rtt = self.rtt * 0.8 + sample * 0.2
    end
  elseif typ == T.LOBBY then
    local tbl = Pack.decode(data, 9)
    if type(tbl) == "table" then self:push("lobby", tbl) end
  elseif typ == T.START then
    local cfg = Pack.decode(data, 9)
    if type(cfg) == "table" then self:push("start", cfg) end
  elseif typ == T.START_ACK then
    self:push "start_ack"
  elseif typ == T.BYE then
    self.state = "closed"
    self:push("disconnected", { reason = "the other player left" })
  end
end

function Session:flush(now)
  local q = self.outq
  local i = 1
  while i <= #q do
    if q[i].at <= now then
      self.sock:send(q[i].ip, q[i].port, q[i].data)
      table.remove(q, i)
    else
      i = i + 1
    end
  end
end

function Session:update()
  local now = sys.time()
  if self.sim then self:flush(now) end
  for _ = 1, 256 do
    local data, ip, port = self.sock:recv()
    if not data then break end
    self:on_packet(data, ip, port, now)
  end
  self:update_stun(now)
  if
    (self.state == "connecting" or self.state == "handshake") and now - (self.hello_t or 0) > 0.15
  then
    self.hello_t = now
    local dst = self.peer or self.target
    if dst then self:raw_send(dst.ip, dst.port, self:hello_packet()) end
  end
  if self.state == "connected" then
    if now - (self.ping_t or 0) > 0.5 then
      self.ping_t = now
      self:send(T.PING, string.pack("<d", now))
    end
    if now - self.last_recv > 6 then
      self:close "timeout"
      self:push("disconnected", { reason = "connection lost" })
    end
  end
end

function Session:destroy()
  if self.state ~= "closed" then self:close "quit" end
  self.sock:close()
end

return Session
