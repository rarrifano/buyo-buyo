-- An online match: Match + Rollback + Session glued together.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Per 60 Hz tick:
--   1. inputs from the peer are fed to the rollback engine (Session callback)
--   2. time sync: if we run ahead of the peer we hold one frame, so both
--      sides stay close and rollbacks stay short
--   3. the rollback engine advances (predicting / correcting as needed)
--   4. all our unacknowledged inputs are sent again (packet loss recovery)
--   5. checksums of confirmed frames are exchanged to detect desyncs
-- Events produced while re-simulating frames are de-duplicated, so sounds
-- and effects fire once.
local Rollback = require "net.rollback"

local NetGame = {}
NetGame.__index = NetGame

-- opts: delay (frames), max_prediction (frames)
function NetGame.new(session, match, local_player, opts)
  opts = opts or {}
  local ng = setmetatable({
    s = session,
    m = match,
    me = local_player,
    remote_checks = {},
    local_checks = {},
    desync = nil,
    remote_frame = 0,
    adv = 0,
    skip_cool = 0,
    skips = 0,
    stalled = 0,
    seen = {},
  }, NetGame)
  ng.rb = Rollback.new(match, {
    local_player = local_player,
    delay = opts.delay or 2,
    max_prediction = opts.max_prediction or 8,
    on_checksum = function(f, sum)
      ng.local_checks[f] = sum
      session:send_check(f, sum)
      ng:compare(f)
    end,
  })
  session.on_input = function(start, masks, ack, their_frame)
    for j = 1, #masks do
      ng.rb:add_remote_input(start + j - 1, masks:byte(j))
    end
    ng.rb:set_peer_ack(ack)
    if their_frame > ng.remote_frame then ng.remote_frame = their_frame end
  end
  session.on_check = function(f, sum)
    ng.remote_checks[f] = sum
    ng:compare(f)
  end
  -- de-duplicate events from re-simulated frames
  local deliver = match.on_event
  match.on_event = function(p, name, data, m)
    local f = ng.rb.current
    local bucket = ng.seen[f]
    if not bucket then
      bucket = {}
      ng.seen[f] = bucket
    end
    local key = (p and p.id or 0)
      .. name
      .. tostring(data and (data.i or data.chain or data.n) or "")
    if bucket[key] then return end
    bucket[key] = true
    if deliver then deliver(p, name, data, m) end
  end
  return ng
end

function NetGame:compare(f)
  local a, b = self.local_checks[f], self.remote_checks[f]
  if a and b and a ~= b and not self.desync then
    self.desync = f
    print(string.format("[net] DESYNC at frame %d (local %08x, remote %08x)", f, a, b))
  end
end

-- one 60 Hz tick; returns true if the simulation advanced
function NetGame:tick(local_mask)
  local rb = self.rb
  local rtt_frames = self.s.rtt * 60
  local ahead = rb.frame - (self.remote_frame + rtt_frames / 2)
  self.adv = self.adv * 0.9 + ahead * 0.1
  local advanced
  if self.adv > 1.5 and self.skip_cool <= 0 and rb.frame > 60 then
    self.skip_cool = 6
    self.skips = self.skips + 1
    rb:idle()
    advanced = false
  else
    advanced = rb:update(local_mask)
  end
  if self.skip_cool > 0 then self.skip_cool = self.skip_cool - 1 end
  self.stalled = advanced and 0 or self.stalled + 1
  local from, list = rb:unacked_local(40)
  self.s:send_input(from, list, rb.remote_confirmed, rb.frame)
  -- forget old dedup buckets
  self.seen[rb.frame - 90] = nil
  return advanced
end

-- is the current state final (no pending prediction)?
function NetGame:confirmed() return self.rb.remote_confirmed >= self.rb.frame - 1 end

-- the match is over AND every input up to the frame where it ended is
-- confirmed, so no rollback can change the result any more
function NetGame:confirmed_done()
  local m = self.m
  return m.state == "done" and m.done_tick ~= nil and self.rb.remote_confirmed >= m.done_tick - 1
end

function NetGame:stats()
  local rb = self.rb
  return {
    ping = math.floor(self.s.rtt * 1000 + 0.5),
    delay = rb.delay,
    rollbacks = rb.stats.rollbacks,
    max_depth = rb.stats.max_depth,
    depth = math.max(0, rb:prediction_depth()),
    stalls = rb.stats.stalls,
    skips = self.skips,
  }
end

return NetGame
