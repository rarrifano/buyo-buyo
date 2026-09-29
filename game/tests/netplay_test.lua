-- Netplay self-test (no sockets): two peers, each running a Match inside a
-- Rollback session, connected by a simulated network with latency, jitter
-- and packet loss. AI bots play both sides on their own (predicted) view.
--
-- Verifies:
--   * snapshot -> continue -> restore -> continue reproduces the same state,
--   * both peers compute identical checksums for every confirmed frame,
--   * replaying the confirmed input streams on a fresh Match WITHOUT rollback
--     reproduces those checksums (the rollback path == the straight path).
--
-- Run: buyo-buyo --headless -- --test    or    lua game/tests/netplay_test.lua
-- SPDX-License-Identifier: GPL-2.0-or-later
local modname = ...
if modname ~= "tests.netplay_test" then
  package.path = "game/?.lua;" .. package.path
  sys = sys or { time = os.clock }
end

local Match = require "puyo.match"
local Rollback = require "net.rollback"
local AI = require "puyo.ai"
local U = require "core.util"

local function snapshot_roundtrip(seed)
  local m = Match.new { seed = seed }
  local bots = { AI.new(4, 1), AI.new(3, 2) }
  local function frame()
    m:step(bots[1]:update(m.players[1], m), bots[2]:update(m.players[2], m))
  end
  for _ = 1, 900 do frame() end
  local snap = m:save()
  local masks = {}
  for f = 1, 600 do
    local a, b = bots[1]:update(m.players[1], m), bots[2]:update(m.players[2], m)
    masks[f] = { a, b }
    m:step(a, b)
  end
  local want = m:checksum()
  m:load(snap)
  for f = 1, 600 do m:step(masks[f][1], masks[f][2]) end
  return m:checksum() == want
end

local function net_match(seed, latency, jitter, loss, delay)
  local rng = U.rng(seed * 31 + 7)
  local peers, wire = {}, {}
  local history = { {}, {} } -- the real input streams, as confirmed
  local checks = { {}, {} }
  local rules = { first_to = 1 }
  for i = 1, 2 do
    local m = Match.new { seed = seed, rules = rules }
    local rb = Rollback.new(m, {
      local_player = i, delay = delay, max_prediction = 8,
      on_checksum = function(f, sum) checks[i][f] = sum end,
    })
    peers[i] = { m = m, rb = rb, ai = AI.new(3 + (i - 1), seed + i), logged = -1 }
  end

  local ticks, drain = 0, nil
  while ticks < 60 * 60 * 8 do
    ticks = ticks + 1
    for i = 1, 2 do
      local P = peers[i]
      -- deliver due packets
      for k = #wire, 1, -1 do
        local pk = wire[k]
        if pk.to == i and pk.at <= ticks then
          table.remove(wire, k)
          for j = 1, #pk.masks do P.rb:add_remote_input(pk.from + j - 1, pk.masks[j]) end
          P.rb:set_peer_ack(pk.ack)
        end
      end
      if drain then P.rb:idle() else P.rb:update(P.ai:update(P.m.players[i], P.m)) end
      -- log our own inputs as they get scheduled (the ground truth)
      for f = P.logged + 1, P.rb.local_scheduled do history[i][f] = P.rb.inputs[i][f] end
      P.logged = P.rb.local_scheduled
      -- send every unacknowledged input (redundancy covers packet loss)
      local from, list = P.rb:unacked_local(40)
      if rng:int(1, 100) > loss then
        wire[#wire + 1] = { to = 3 - i, at = ticks + latency + rng:int(0, jitter), from = from,
                            masks = list, ack = P.rb.remote_confirmed }
      end
    end
    -- once both (predicted) matches are over, stop advancing and let the
    -- last inputs arrive so every frame gets confirmed
    if not drain and peers[1].m.state == "done" and peers[2].m.state == "done" then drain = ticks end
    if drain then
      local settled = true
      for i = 1, 2 do
        local P = peers[i]
        if P.rb.remote_confirmed < P.rb.frame - 1 then settled = false end
      end
      if (settled and #wire == 0) or ticks - drain > 600 then break end
    end
  end

  -- compare peer checksums
  local common, mismatch = 0, 0
  for f, sum in pairs(checks[1]) do
    local other = checks[2][f]
    if other then
      common = common + 1
      if other ~= sum then mismatch = mismatch + 1 end
    end
  end
  -- straight replay of the confirmed inputs
  local ref = Match.new { seed = seed, rules = rules }
  local replay_bad, last = 0, math.min(peers[1].rb.frame, peers[2].rb.frame) - 1
  for f = 0, last do
    local a, b = history[1][f], history[2][f]
    if a == nil or b == nil then break end
    ref:step(a, b)
    if f % Rollback.CHECK_INTERVAL == 0 and checks[1][f] and checks[1][f] ~= ref:checksum() then
      replay_bad = replay_bad + 1
    end
  end
  local s1, s2 = peers[1].rb.stats, peers[2].rb.stats
  return {
    common = common, mismatch = mismatch, replay_bad = replay_bad, ticks = ticks,
    frames = peers[1].rb.frame, done = peers[1].m.state == "done" and peers[2].m.state == "done",
    rollbacks = s1.rollbacks + s2.rollbacks, depth = math.max(s1.max_depth, s2.max_depth),
    stalls = s1.stalls + s2.stalls, winner = peers[1].m:champion(), winner2 = peers[2].m:champion(),
  }
end

return (function()
  local function run()
    local ok = true
    for _, seed in ipairs { 3, 11 } do
      local good = snapshot_roundtrip(seed)
      print(string.format("netplay test: snapshot round-trip seed %d: %s", seed, good and "ok" or "FAILED"))
      ok = ok and good
    end
    local nets = {
      { name = "LAN",        lat = 1,  jit = 0, loss = 0,  delay = 1 },
      { name = "internet",   lat = 5,  jit = 3, loss = 5,  delay = 2 },
      { name = "bad wifi",   lat = 9,  jit = 8, loss = 20, delay = 2 },
      { name = "far away",   lat = 14, jit = 4, loss = 3,  delay = 3 },
    }
    for k, n in ipairs(nets) do
      local r = net_match(100 + k, n.lat, n.jit, n.loss, n.delay)
      local good = r.done and r.mismatch == 0 and r.replay_bad == 0 and r.common > 10 and r.winner == r.winner2
      print(string.format("netplay test: %-9s %4d frames, %3d checks equal, %4d rollbacks (max %2d frames), %4d stalls, winner P%s: %s",
        n.name, r.frames, r.common - r.mismatch, r.rollbacks, r.depth, r.stalls, tostring(r.winner),
        good and "ok" or ("FAILED" .. (r.done and "" or " (not finished)") ..
        (r.mismatch > 0 and (" desync x" .. r.mismatch) or "") .. (r.replay_bad > 0 and (" replay x" .. r.replay_bad) or ""))))
      ok = ok and good
    end
    return ok
  end
  if modname == "tests.netplay_test" then return run end
  os.exit(run() and 0 or 1)
end)()
