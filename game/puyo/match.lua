-- A versus match: two players sharing one pair sequence, nuisance exchange,
-- margin time, "first to N" rounds, and the game mode's hooks.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- The whole match advances ONLY through Match:step(mask1, mask2), one call
-- per 60 Hz frame. Given the same seed, mode and input masks it produces the
-- same result on every machine - that is what makes rollback netplay work.
-- Match:save()/load() snapshot the complete simulation state.
local Rules = require "puyo.rules"
local Player = require "puyo.player"
local Sequence = require "puyo.sequence"
local U = require "core.util"

local Match = {}
Match.__index = Match

local mix = Player.mix

-- opts:
--   seed          integer
--   mode          a mode definition (content/modes/*) or nil for plain rules
--   base_rules    rule overrides applied BEFORE the mode's (user settings, e.g. colors)
--   rules         rule overrides applied AFTER the mode's (match options, e.g. first_to)
--   hard_drop     { bool, bool } per-player preference
--   on_event      function(player_or_nil, name, data, match)
--   on_hook_error function(hook_name, message)
function Match.new(opts)
  local m = setmetatable({}, Match)
  m.opts = opts
  m.mode = opts.mode
  m.R = Rules.make(opts.base_rules, m.mode and m.mode.rules, opts.rules)
  m.on_event = opts.on_event
  m.seed = math.tointeger(opts.seed) or 1
  m.seeds = U.rng(m.seed)
  m.rng = U.rng(m.seed ~ 0x5bd1e995) -- for modes: m.rng:int(a, b)
  m.data = {}                        -- free-form mode state (snapshotted)
  m.disabled_hooks = {}
  m.players = { Player.new(1, m), Player.new(2, m) }
  m.players[1].opponent = m.players[2]
  m.players[2].opponent = m.players[1]
  for i = 1, 2 do
    local pref = opts.hard_drop and opts.hard_drop[i]
    m.players[i].hard_drop_enabled = pref ~= false
  end
  m.wins = { 0, 0 }
  m.round = 0
  m.tick = 0
  m:hook("init")
  m:new_round()
  return m
end

function Match:emit(p, name, data)
  if self.on_event then self.on_event(p, name, data, self) end
end

-- Call a mode hook. A hook that raises an error is reported and disabled
-- (identically on both machines, so netplay stays in sync).
function Match:hook(name, ...)
  local mode = self.mode
  local f = mode and mode[name]
  if type(f) ~= "function" or self.disabled_hooks[name] then return nil end
  local ok, a, b = pcall(f, self, ...)
  if not ok then
    self.disabled_hooks[name] = true
    local msg = string.format("mode '%s' hook '%s' failed and was disabled: %s", mode.id or "?", name, tostring(a))
    print(msg)
    if self.opts.on_hook_error then self.opts.on_hook_error(name, msg) end
    return nil
  end
  return a, b
end

function Match:new_round()
  self.round = self.round + 1
  local seed = self.seeds:next()
  self.seq = Sequence.new(seed, self.R.colors)
  for i, p in ipairs(self.players) do p:reset(seed + i * 7919) end
  self.frames = 0
  self.target_points = self.R.target_points
  self.gravity = self.R.gravity
  self.state = "ready"
  self.timer = 0
  self.round_winner = nil
  self:hook("round_start")
  self:emit(nil, "round_start", { round = self.round })
end

-- A chain link produced `amount` nuisance: first offset our own pending
-- nuisance, the rest goes to the opponent.
function Match:attack(from, amount)
  if amount <= 0 then return end
  local offset = math.min(from.pending, amount)
  if offset > 0 then
    from.pending = from.pending - offset
    amount = amount - offset
    from:emit("offset", { n = offset })
  end
  if amount > 0 then
    local to = from.opponent
    to.pending = to.pending + amount
    from.sent = from.sent + amount
    from:emit("send", { n = amount, to = to })
  end
end

function Match:end_round(winner)
  self.state = "over"
  self.timer = 0
  self.round_winner = winner
  if winner > 0 then self.wins[winner] = self.wins[winner] + 1 end
  self:emit(nil, "round_over", { winner = winner })
end

-- winner of the whole match, or nil
function Match:champion()
  for i = 1, 2 do
    if self.wins[i] >= self.R.first_to then return i end
  end
  return nil
end

-- advance the simulation by exactly one frame
function Match:step(m1, m2)
  self.tick = self.tick + 1
  local st = self.state
  if st == "ready" then
    self.timer = self.timer + 1
    if self.timer >= self.R.ready_time then
      self.state = "play"
      for _, p in ipairs(self.players) do p:start() end
      self:emit(nil, "go")
    end
  elseif st == "play" then
    self.frames = self.frames + 1
    self.target_points = Rules.target_points(self.R, self.frames)
    local p1, p2 = self.players[1], self.players[2]
    p1:update(m1)
    p2:update(m2)
    self:hook("frame")
    local w = self:hook("winner")
    if w == 0 or w == 1 or w == 2 then
      self:end_round(w)
    elseif p1.dead or p2.dead then
      self:end_round((p1.dead and p2.dead) and 0 or (p2.dead and 1 or 2))
    end
  elseif st == "over" then
    self.timer = self.timer + 1
    if self.timer >= self.R.over_time then
      if self:champion() then
        self.state = "done"
        self.done_tick = self.tick
        self:emit(nil, "match_over", { winner = self:champion() })
      else
        self:new_round()
      end
    end
  end
end

------------------------------------------------------------------------
-- snapshots / checksums
------------------------------------------------------------------------

local copy = Rules.copy

function Match:save()
  return {
    tick = self.tick, frames = self.frames, target_points = self.target_points, gravity = self.gravity,
    state = self.state, timer = self.timer, round_winner = self.round_winner, round = self.round,
    done_tick = self.done_tick,
    w1 = self.wins[1], w2 = self.wins[2],
    seeds = self.seeds.s, rng = self.rng.s,
    seq = self.seq, seqst = self.seq:save(),
    p1 = self.players[1]:save(), p2 = self.players[2]:save(),
    data = copy(self.data),
    disabled = copy(self.disabled_hooks),
  }
end

function Match:load(s)
  self.tick, self.frames, self.target_points, self.gravity = s.tick, s.frames, s.target_points, s.gravity
  self.state, self.timer, self.round_winner, self.round = s.state, s.timer, s.round_winner, s.round
  self.done_tick = s.done_tick
  self.wins[1], self.wins[2] = s.w1, s.w2
  self.seeds.s, self.rng.s = s.seeds, s.rng
  self.seq = s.seq
  self.seq:load(s.seqst)
  self.players[1]:load(s.p1)
  self.players[2]:load(s.p2)
  self.data = copy(s.data)
  self.disabled_hooks = copy(s.disabled)
end

local STATE_ID = { ready = 1, play = 2, over = 3, done = 4 }

function Match:checksum()
  local h = 2166136261
  h = mix(h, self.tick)
  h = mix(h, self.frames)
  h = mix(h, STATE_ID[self.state] or 0)
  h = mix(h, self.timer)
  h = mix(h, self.wins[1])
  h = mix(h, self.wins[2])
  h = mix(h, self.seeds.s)
  h = mix(h, self.rng.s)
  -- NB: not the pair generator's RNG: the NEXT preview and the AI pre-generate
  -- pairs from outside the simulation. Content is identical either way;
  -- what matters (each player's position in the sequence) is hashed below.
  h = self.players[1]:hash(h)
  h = self.players[2]:hash(h)
  return h
end

return Match
