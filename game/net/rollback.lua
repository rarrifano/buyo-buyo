-- GGPO-style rollback for a deterministic two-player simulation.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- The simulation object must provide:
--   sim:save() -> snapshot     sim:load(snapshot)
--   sim:step(mask1, mask2)     sim:checksum() -> integer
--
-- Every tick:
--   rb:add_remote_input(frame, mask)   for each input that arrived (any order, dupes ok)
--   rb:update(local_mask)              rolls back if needed, then advances one frame
--
-- Local input is delayed by `delay` frames (hides small latencies); the
-- remote input for frames we have not received yet is predicted (= last
-- known input). When the real input arrives and differs, we load the
-- snapshot taken before that frame and re-simulate up to the present.
-- We never predict more than `max_prediction` frames ahead: past that we
-- stall until the peer's inputs arrive.
local Rollback = {}
Rollback.__index = Rollback

Rollback.CHECK_INTERVAL = 30 -- checksum every N confirmed frames

-- opts: local_player (1|2), delay (frames), max_prediction (frames),
--       on_checksum(frame, sum)
function Rollback.new(sim, opts)
  local rb = setmetatable({}, Rollback)
  rb.sim = sim
  rb.me = opts.local_player
  rb.them = 3 - rb.me
  rb.delay = math.max(0, opts.delay or 2)
  rb.max_pred = math.max(1, opts.max_prediction or 8)
  rb.on_checksum = opts.on_checksum
  rb.frame = 0                 -- next frame to simulate
  rb.current = 0               -- frame being simulated right now (for event tagging)
  rb.inputs = { {}, {} }       -- inputs by frame (ours are known when scheduled)
  rb.predicted = {}            -- remote input used when frame f was simulated
  rb.states = {}               -- snapshot taken BEFORE simulating frame f
  rb.checks = {}               -- our checksums of confirmed frames
  rb.provisional = {}          -- checksums computed with (possibly) predicted inputs
  rb.next_check = 0
  rb.remote_confirmed = -1     -- every remote input <= this frame is known
  rb.local_scheduled = -1      -- highest frame holding a local input
  rb.peer_ack = -1             -- highest local frame the peer confirmed receiving
  rb.gc_floor = 0              -- inputs below this frame are gone
  rb.state_floor = 0           -- snapshots below this frame are gone
  rb.rollback_to = nil
  rb.resimulating = false
  rb.stats = { rollbacks = 0, resimulated = 0, max_depth = 0, stalls = 0 }
  return rb
end

-- remote input arrived (from the network)
function Rollback:add_remote_input(f, mask)
  if f <= self.remote_confirmed then return end
  local t = self.inputs[self.them]
  if t[f] ~= nil then return end
  t[f] = mask
  while t[self.remote_confirmed + 1] ~= nil do self.remote_confirmed = self.remote_confirmed + 1 end
  if f < self.frame and self.predicted[f] ~= mask then
    if not self.rollback_to or f < self.rollback_to then self.rollback_to = f end
  end
end

-- local inputs the peer has not acknowledged yet: first frame, list of masks
function Rollback:unacked_local(limit)
  local from = math.max(self.peer_ack + 1, self.gc_floor)
  local to = math.min(self.local_scheduled, from + (limit or 64) - 1)
  local list = {}
  local t = self.inputs[self.me]
  for f = from, to do list[#list + 1] = t[f] end
  return from, list
end

function Rollback:set_peer_ack(f)
  if f > self.peer_ack then self.peer_ack = math.min(f, self.local_scheduled) end
end

-- prediction: repeat the most recent confirmed input
function Rollback:remote_input(f)
  local t = self.inputs[self.them]
  local m = t[f]
  if m ~= nil then return m end
  return t[self.remote_confirmed] or 0
end

function Rollback:simulate(f)
  self.states[f] = self.sim:save()
  local r = self:remote_input(f)
  self.predicted[f] = r
  local l = self.inputs[self.me][f]
  self.current = f
  if self.me == 1 then self.sim:step(l, r) else self.sim:step(r, l) end
  -- provisional: becomes final once every input up to f is confirmed (a
  -- rollback that touches f recomputes it before that happens)
  if f % Rollback.CHECK_INTERVAL == 0 then self.provisional[f] = self.sim:checksum() end
end

function Rollback:finalize_checks()
  local f = self.next_check
  while f <= self.remote_confirmed and f < self.frame do
    local sum = self.provisional[f]
    if sum then
      self.provisional[f] = nil
      self.checks[f] = sum
      if self.on_checksum then self.on_checksum(f, sum) end
    end
    f = f + Rollback.CHECK_INTERVAL
  end
  self.next_check = f
end

-- process corrections without advancing (e.g. after the match ended)
function Rollback:idle()
  if self.rollback_to then self:do_rollback() end
  self:finalize_checks()
end

function Rollback:do_rollback()
  local f = self.rollback_to
  self.rollback_to = nil
  local st = self.states[f]
  if not st then error("rollback: no snapshot for frame " .. f .. " (window too small?)") end
  self.sim:load(st)
  self.resimulating = true
  for g = f, self.frame - 1 do self:simulate(g) end
  self.resimulating = false
  local depth = self.frame - f
  self.stats.rollbacks = self.stats.rollbacks + 1
  self.stats.resimulated = self.stats.resimulated + depth
  if depth > self.stats.max_depth then self.stats.max_depth = depth end
end

-- frames we are ahead of the last confirmed remote frame
function Rollback:prediction_depth() return self.frame - 1 - self.remote_confirmed end

function Rollback:can_advance() return self.frame - self.remote_confirmed <= self.max_pred end

-- one tick: keep the local input queue `delay` frames ahead, fix
-- mispredictions, then advance one frame if the prediction window allows.
function Rollback:update(local_mask)
  while self.local_scheduled < self.frame + self.delay do
    self.local_scheduled = self.local_scheduled + 1
    -- the very first `delay` frames nobody can have input yet
    self.inputs[self.me][self.local_scheduled] = self.local_scheduled < self.delay and 0 or local_mask
  end
  if self.rollback_to then self:do_rollback() end
  if not self:can_advance() then
    self.stats.stalls = self.stats.stalls + 1
    self:finalize_checks()
    return false
  end
  self:simulate(self.frame)
  self.frame = self.frame + 1
  self:finalize_checks()
  self:gc()
  return true
end

-- forget what can never be needed again
function Rollback:gc()
  -- snapshots: the oldest possible rollback target is the first frame whose
  -- remote input is still unknown
  local keep_state = math.min(self.remote_confirmed + 1, self.frame)
  for f = self.state_floor, keep_state - 1 do
    self.states[f] = nil
    self.predicted[f] = nil
  end
  if keep_state > self.state_floor then self.state_floor = keep_state end
  -- inputs: keep the last confirmed remote one (used for prediction) and
  -- every local one the peer has not acknowledged (resent redundantly)
  local keep_input = math.min(self.remote_confirmed, self.peer_ack + 1)
  local me, them = self.inputs[self.me], self.inputs[self.them]
  for f = self.gc_floor, keep_input - 1 do
    me[f] = nil
    them[f] = nil
  end
  if keep_input > self.gc_floor then self.gc_floor = keep_input end
  local old = self.frame - 1200
  if old > 0 and old % Rollback.CHECK_INTERVAL == 0 then self.checks[old] = nil end
end

return Rollback
