-- The versus screen: stage, two fields, character portraits, HUD, pause,
-- results. Drives the simulation locally or through NetGame (online).
-- SPDX-License-Identifier: GPL-2.0-or-later
local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Content = require "core.content"
local Jukebox = require "core.jukebox"
local U = require "core.util"
local Rules = require "puyo.rules"
local Match = require "puyo.match"
local Player = require "puyo.player"
local AI = require "puyo.ai"
local NetGame = require "net.netgame"
local Field = require "view.field"
local FX = require "view.fx"
local UI = require "view.ui"
local Skin = require "view.skin"
local Stage = require "view.stage"
local Char = require "view.char"

local Versus = {}
Versus.__index = Versus

local FIELD_Y = 104
local FIELD_X = { 112, 880 }
local NEXT_X = { 422, 746 }
local PAN = { -0.45, 0.45 }
local BTN = Player.BUTTONS

-- a random CPU vs CPU match for the title screen attract mode
function Versus.demo_config()
  local chars = Content.list("chars")
  local function pick() local d = chars[math.random(1, math.max(1, #chars))]; return d and d.id end
  return {
    kind = "watch", demo = true, seed = os.time(), mode_id = "tsu", first_to = 1,
    stage_id = "default", music_id = "auto", colors = Settings.data.colors,
    players = { { char = pick(), cpu = true, level = 3 }, { char = pick(), cpu = true, level = 4 } },
  }
end

local function char_def(p)
  local d = Content.get("chars", p.char)
  if d then return d end
  -- the remote player's character is not installed here: show a stand-in
  return { id = p.char or "?", kind = "chars", name = p.char_name or p.char or "???",
           color = p.char_color or { 200, 200, 200 } }
end

-- cfg: see Select:build_config (kind, seed, mode_id, first_to, stage_id,
-- music_id, colors, players = { {char, cpu, remote, level, hard_drop}, ... },
-- session, local_player, delay, demo, quit_at_end, net_bot)
function Versus.new(cfg)
  local self = setmetatable({ cfg = cfg, t = 0, ai = {}, ctl = {}, fx = FX.new(), mood_t = { 0, 0 } }, Versus)
  self.mode = Content.get("modes", cfg.mode_id) or Content.pick("modes", "tsu")
  self.chars = { char_def(cfg.players[1]), char_def(cfg.players[2]) }
  local skin_pref = Settings.data.skin
  self.skins = {}
  for i = 1, 2 do
    local sid = (skin_pref and skin_pref ~= "character") and skin_pref or self.chars[i].skin
    self.skins[i] = Skin.get(sid)
  end
  self.stage = Stage.new(Content.pick("stages", cfg.stage_id))
  self.match = Match.new {
    seed = cfg.seed,
    mode = self.mode,
    base_rules = { colors = cfg.colors },
    rules = { first_to = cfg.first_to },
    hard_drop = { cfg.players[1].hard_drop ~= false, cfg.players[2].hard_drop ~= false },
    on_event = function(p, name, d) self:on_event(p, name, d) end,
    on_hook_error = function(_, msg) Content.report("modes", self.mode and self.mode.id or "?", msg) end,
  }
  for i = 1, 2 do
    local p = cfg.players[i]
    if p.cpu or (cfg.net_bot and not p.remote) then
      self.ai[i] = AI.new(p.level or cfg.net_bot or 2, cfg.seed + i * 101, self.chars[i].cpu)
    end
  end
  if cfg.kind == "online" then
    self.net = NetGame.new(cfg.session, self.match, cfg.local_player, { delay = cfg.delay or 2 })
  end
  self.names = {}
  for i = 1, 2 do
    local p = cfg.players[i]
    local tag = p.cpu and ("CPU " .. AI.LEVELS[p.level or 2].name) or (p.remote and "REMOTE" or (i == 1 and "1P" or "2P"))
    self.names[i] = self.chars[i].name:upper()
    self.tags = self.tags or {}
    self.tags[i] = tag
  end
  self.totals = { { score = 0, chain = 0, sent = 0 }, { score = 0, chain = 0, sent = 0 } }
  self:build_fields()
  return self
end

function Versus:build_fields()
  self.fields = {}
  for i = 1, 2 do
    local human = not self.cfg.players[i].cpu and not self.cfg.players[i].remote
    self.fields[i] = Field.new(self.match.players[i], FIELD_X[i], FIELD_Y, i == 1 and -1 or 1,
                               { skin = self.skins[i], ghost = Settings.data.ghost and human })
  end
end

function Versus:enter()
  local kind = self.cfg.kind
  if kind == "cpu" then
    self.ctl[1] = Controls.register("solo", "all")
  elseif kind == "2p" then
    self.ctl[1] = Controls.register("p1", { 1 })
    self.ctl[2] = Controls.register("p2", { 2 })
  elseif kind == "online" then
    self.ctl[self.cfg.local_player] = Controls.register("solo", "all")
  end
  self:play_battle_music()
end

function Versus:leave()
  for _, c in pairs(self.ctl) do Controls.unregister(c) end
end

function Versus:play_battle_music()
  local id = self.cfg.music_id
  if not id or id == "auto" then
    id = (self.stage.def and self.stage.def.music) or self.chars[2].music or "battle"
  end
  Jukebox.current = nil
  Jukebox.play(id, "battle")
end

function Versus:is_local_human(i)
  local p = self.cfg.players[i]
  return not p.cpu and not p.remote
end

------------------------------------------------------------------------
-- events from the simulation
------------------------------------------------------------------------

function Versus:on_event(p, name, d)
  if not p then return self:on_match_event(name, d) end
  local f = self.fields[p.id]
  f:on_event(name, d)
  local pan = PAN[p.id]
  local def = self.chars[p.id]
  if name == "move" or name == "rotate" then
    if self:is_local_human(p.id) then Sound.play(name, pan) end
  elseif name == "lock" then
    Sound.play("lock", pan)
  elseif name == "hard_drop" then
    Sound.play("harddrop", pan)
  elseif name == "land" then
    if p.state == "garbage" then
      Sound.play("garbage", pan, f.incoming > 0 and f.incoming or 6)
    else
      Sound.play("land", pan)
    end
  elseif name == "garbage" then
    self.mood_t[p.id] = 60
    if d.n >= 18 then Char.voice(def, "damage", d.n, pan) end
  elseif name == "pop" then
    Sound.play("pop", pan, d.chain)
    Char.voice(def, "chain", d.chain, pan)
  elseif name == "send" then
    local target = self.fields[d.to.id]
    local tx, ty = target:tray_point()
    local col = d.n >= 30 and { 255, 120, 90 } or { 255, 220, 120 }
    self.fx:bolt(f.last_pop_x or f.x + f.w / 2, f.last_pop_y or f.y + f.h / 2, tx, ty, col)
    Sound.play("send", pan, d.n)
    if d.n >= 30 then Char.voice(def, "attack", d.n, pan) end
  elseif name == "offset" then
    local tx, ty = f:tray_point()
    self.fx:bolt(f.last_pop_x or f.x + f.w / 2, f.last_pop_y or f.y + f.h / 2, tx, ty, { 160, 220, 255 })
    Sound.play("offset", pan)
  elseif name == "all_clear" then
    Sound.play("all_clear", pan)
    Char.voice(def, "all_clear", 1, pan)
  elseif name == "die" then
    Sound.play("die", pan)
  end
end

function Versus:on_match_event(name, d)
  local m = self.match
  if not m then return end -- events emitted while the match is being created
  if name == "round_start" then
    for _, f in ipairs(self.fields or {}) do f:reset() end
    for _, ai in pairs(self.ai) do ai:reset() end
    if m.round > 1 then self:play_battle_music() end
  elseif name == "go" then
    Sound.play("go")
  elseif name == "round_over" then
    for i = 1, 2 do
      local p, tot = m.players[i], self.totals[i]
      tot.score = tot.score + p.score
      tot.chain = math.max(tot.chain, p.max_chain)
      tot.sent = tot.sent + p.sent
    end
    local w = d.winner
    local me = self.cfg.kind == "online" and self.cfg.local_player or (self.cfg.kind == "cpu" and 1 or nil)
    Jukebox.play((me and w ~= me and w ~= 0) and "lose" or "win")
    if w > 0 then
      Char.voice(self.chars[w], "win", 1, PAN[w])
      Char.voice(self.chars[3 - w], "lose", 1, PAN[3 - w])
    end
    if sys.headless() then
      print(string.format("[round %d] winner=%s  score %d/%d  max chain %d/%d  sent %d/%d  time %.1fs",
        m.round, w == 0 and "draw" or ("P" .. w), m.players[1].score, m.players[2].score,
        m.players[1].max_chain, m.players[2].max_chain, m.players[1].sent, m.players[2].sent, m.frames / 60))
    end
  elseif name == "announce" then
    self.fx:popup(tostring(d.text or ""), 640, 330, { scale = 5, col = d.color or UI.YELLOW, life = 90, rise = 0.3 })
  end
end

------------------------------------------------------------------------
-- input
------------------------------------------------------------------------

local function controller_mask(c)
  local h = c.held
  local m = 0
  if h.left then m = m | BTN.left end
  if h.right then m = m | BTN.right end
  if h.up then m = m | BTN.up end
  if h.down then m = m | BTN.down end
  if h.rot_l then m = m | BTN.rot_l end
  if h.rot_r then m = m | BTN.rot_r end
  return m
end

function Versus:local_mask(i)
  if self.ai[i] then return self.ai[i]:update(self.match.players[i], self.match) end
  local c = self.ctl[i]
  return c and controller_mask(c) or 0
end

------------------------------------------------------------------------
-- flow
------------------------------------------------------------------------

function Versus:quit_to_title()
  if self.net then self.net.s:destroy() end
  Scene.go(require("scenes.title").new())
end

function Versus:to_select()
  local Select = require "scenes.select"
  Scene.go(Select.new { mode = self.cfg.kind })
end

function Versus:restart()
  local cfg = U.copy(self.cfg)
  cfg.seed = (cfg.seed * 1103515245 + 12345) & 0x7fffffff
  Scene.go(Versus.new(cfg))
end

function Versus:update_online()
  local ng, s = self.net, self.net.s
  s:update()
  for _, ev in ipairs(s:poll()) do
    if ev.name == "disconnected" or ev.name == "error" then
      self.net_error = ev.data.reason or ev.data.msg or "disconnected"
    elseif ev.name == "start" then
      if self.cfg.local_player == 2 and self.results then
        s:send_start_ack()
        return self:launch_rematch(ev.data)
      elseif self.cfg.local_player == 2 then
        s:send_start_ack() -- our ack got lost: say it again
      end
    elseif ev.name == "start_ack" and self.rematch_cfg then
      return self:launch_rematch(self.rematch_cfg)
    elseif ev.name == "lobby" and ev.data.rematch then
      self.peer_rematch = true
    end
  end
  if self.results then
    ng.rb:idle()
    if self.t % 6 == 0 and self.results.want_rematch then s:send_lobby({ rematch = true }) end
    if self.cfg.local_player == 1 and self.results.want_rematch and self.peer_rematch then
      if not self.rematch_cfg then
        self.rematch_cfg = U.copy(self.cfg)
        self.rematch_cfg.session = nil
        self.rematch_cfg.seed = (self.cfg.seed * 1103515245 + 12345) & 0x7fffffff
      end
      if self.t % 20 == 0 then s:send_start(self.rematch_cfg) end
    end
    return
  end
  ng:tick(self:local_mask(self.cfg.local_player))
end

function Versus:launch_rematch(cfg)
  cfg = U.copy(cfg)
  cfg.kind = "online"
  cfg.session = self.cfg.session
  cfg.local_player = self.cfg.local_player
  cfg.delay = self.cfg.delay
  cfg.net_bot = self.cfg.net_bot
  cfg.quit_at_end = self.cfg.quit_at_end
  for i = 1, 2 do cfg.players[i].remote = i ~= cfg.local_player end
  self.relaunched = true
  Scene.go(Versus.new(cfg))
end

function Versus:update()
  self.t = self.t + 1
  self.stage:update()
  local menu = Controls.menu
  if self.relaunched then return end
  if self.paused then return self:update_pause() end

  if self.cfg.demo then
    if self.any_key or menu.pressed.confirm or menu.pressed.start or menu.pressed.back then
      self.any_key = false
      return self:quit_to_title()
    end
  elseif self.net then
    if self.net_error or self.net.desync then
      if menu.pressed.confirm or menu.pressed.back then return self:quit_to_title() end
    elseif menu.pressed.start and not self.results then
      self.leave_confirm = not self.leave_confirm
    elseif self.leave_confirm and menu.pressed.confirm then
      return self:quit_to_title()
    end
  elseif menu.pressed.start and not self.results then
    self.paused = { sel = 1 }
    Sound.play("menu_ok")
    return
  end

  if self.net then
    self:update_online()
  elseif not self.results then
    self.match:step(self:local_mask(1), self:local_mask(2))
  end

  for i, f in ipairs(self.fields) do
    f:update()
    if self.mood_t[i] > 0 then self.mood_t[i] = self.mood_t[i] - 1 end
  end
  self.fx:update()

  local m = self.match
  if m.state == "done" and not self.results and (not self.net or self.net:confirmed_done()) then
    if self.cfg.quit_at_end then
      if not self.quitting then
        self.quitting = true
        print(string.format("[match] %s wins %d-%d (checksum %08x)", self.names[m:champion()], m.wins[1], m.wins[2],
          m:checksum()))
        if self.net then
          local st = self.net:stats()
          print(string.format("[net] frames %d, rollbacks %d (max %d frames), stalls %d, skips %d, ping %dms, desync %s",
            self.net.rb.frame, st.rollbacks, st.max_depth, st.stalls, st.skips, st.ping, tostring(self.net.desync)))
        end
        if self.net then self.net.s:destroy() end
        sys.quit()
      end
      return
    end
    if self.cfg.demo then return self:quit_to_title() end
    self.results = { sel = 1, t = 0 }
  end
  if self.results then self:update_results() end
end

local PAUSE_ITEMS = { "RESUME", "RESTART", "CHARACTER SELECT", "QUIT TO TITLE" }

function Versus:update_pause()
  local menu, ps = Controls.menu, self.paused
  if menu:rep("up") then ps.sel = (ps.sel - 2) % #PAUSE_ITEMS + 1; Sound.play("menu_move") end
  if menu:rep("down") then ps.sel = ps.sel % #PAUSE_ITEMS + 1; Sound.play("menu_move") end
  if menu.pressed.back or (menu.pressed.start and not menu.pressed.confirm) then
    self.paused = nil
    Sound.play("menu_back")
  elseif menu.pressed.confirm then
    Sound.play("menu_ok")
    if ps.sel == 1 then self.paused = nil
    elseif ps.sel == 2 then self:restart()
    elseif ps.sel == 3 then self:to_select()
    else self:quit_to_title() end
  end
end

function Versus:result_items()
  if self.net then return { "REMATCH", "LEAVE" } end
  return { "REMATCH", "CHARACTER SELECT", "TITLE" }
end

function Versus:update_results()
  local menu, r = Controls.menu, self.results
  local items = self:result_items()
  r.t = r.t + 1
  if r.t < 30 or r.want_rematch then return end
  if self.cfg.net_bot and self.net then r.want_rematch = true return end
  if menu:rep("up") or menu:rep("left") then r.sel = (r.sel - 2) % #items + 1; Sound.play("menu_move") end
  if menu:rep("down") or menu:rep("right") then r.sel = r.sel % #items + 1; Sound.play("menu_move") end
  if menu.pressed.confirm then
    Sound.play("menu_ok")
    local item = items[r.sel]
    if item == "REMATCH" then
      if self.net then r.want_rematch = true else self:restart() end
    elseif item == "CHARACTER SELECT" then
      self:to_select()
    else
      self:quit_to_title()
    end
  elseif menu.pressed.back then
    Sound.play("menu_back")
    self:quit_to_title()
  end
end

function Versus:key(name, down)
  if down and self.cfg.demo then self.any_key = true end
end

function Versus:focus(on)
  if not on and not self.paused and not self.results and not self.cfg.demo
     and self.cfg.kind ~= "watch" and not self.net then
    self.paused = { sel = 1 }
  end
end

------------------------------------------------------------------------
-- drawing
------------------------------------------------------------------------

function Versus:mood(i)
  local m = self.match
  local p = m.players[i]
  if m.state == "over" or m.state == "done" then
    if m.round_winner == i then return "win" end
    if m.round_winner and m.round_winner ~= 0 then return "lose" end
  end
  if p.dead then return "lose" end
  if p.chaining then return "happy" end
  if self.mood_t[i] > 0 then return "hurt" end
  if self.fields[i].danger then return "worried" end
  return "idle"
end

function Versus:draw_center()
  local m = self.match
  local cx = 640
  UI.text("ROUND " .. m.round, cx, 112, 2, "center", UI.GRAY)
  local n = m.R.first_to
  local sc = n > 3 and 2 or 3
  local sw = 8 * sc
  for i = 1, 2 do
    for k = 1, math.min(n, 5) do
      local x = i == 1 and (cx - 10 - k * sw) or (cx + 10 + (k - 1) * sw)
      UI.text("\005", x, 140, sc, "left", k <= m.wins[i] and UI.YELLOW or UI.DIM)
    end
  end
  local pulse = 1 + math.sin(self.t * 0.08) * 0.04
  UI.outline("VS", cx, 190, 6 * pulse, "center", { 255, 230, 120 }, { 70, 20, 60 })
  for i = 1, 2 do
    local x = i == 1 and 536 or 644
    Char.draw(self.chars[i], x, 270, 100, 150, self:mood(i), self.t, i == 2)
  end
  local secs = m.frames // 60
  UI.text(string.format("TIME %d:%02d", secs // 60, secs % 60), cx, 452, 2, "center", UI.GRAY)
  if m.target_points < m.R.target_points then
    local blink = (self.t // 20) % 2 == 0
    UI.text("MARGIN!", cx, 480, 2, "center", blink and { 255, 110, 110 } or { 255, 180, 120 })
    UI.text("RATE " .. m.target_points, cx, 504, 2, "center", { 255, 180, 120 })
  else
    UI.text("RATE " .. m.target_points, cx, 480, 2, "center", UI.DIM)
  end
  UI.text((self.mode and self.mode.name or "?"):upper(), cx, 540, 1.5, "center", UI.DIM)
  if self.mode and type(self.mode.hud) == "function" then
    self.hud_gfx = self.hud_gfx or Content.sandbox_gfx()
    Content.call(self.mode, "hud", m, self.hud_gfx, cx, 566)
    gfx.blend("alpha")
  end
  if self.net then
    local st = self.net:stats()
    UI.text(string.format("PING %d  DELAY %d", st.ping, st.delay), cx, 612, 1.5, "center", UI.DIM)
    UI.text(string.format("ROLLBACK %d", st.depth), cx, 630, 1.5, "center",
            st.depth > 4 and { 255, 180, 120 } or UI.DIM)
    if self.net.stalled > 20 then
      UI.text("WAITING...", cx, 654, 2, "center", { 255, 180, 120 })
    end
  end
  if self.cfg.demo then
    local a = (self.t // 30) % 2 == 0 and 255 or 120
    UI.text("DEMO - PRESS ANY KEY", cx, 668, 1.5, "center", UI.YELLOW, a)
  end
end

function Versus:draw_header()
  for i = 1, 2 do
    local f = self.fields[i]
    local col = self.chars[i].color or (i == 1 and UI.P1 or UI.P2)
    UI.text(self.names[i], f.x + f.w / 2, 10, 3, "center", col)
    UI.text(self.tags[i], f.x + (i == 1 and 0 or f.w), 40, 1.5, i == 1 and "left" or "right", UI.DIM)
  end
end

function Versus:draw_ready()
  local m = self.match
  local go_at = m.R.ready_time - 40
  for _, f in ipairs(self.fields) do
    local cx, cy = f.x + f.w / 2, f.y + f.h * 0.40
    if m.state == "ready" then
      local t = m.timer
      if t < go_at then
        local k = U.ease_out_back(math.min(1, t / 18))
        UI.outline("READY?", cx, cy, 5 * k, "center", UI.YELLOW, { 60, 20, 60 })
      else
        local k = U.ease_out_back(math.min(1, (t - go_at) / 10))
        UI.rainbow("GO!", cx, cy - 8, 8 * k, self.t, "center")
      end
    elseif m.state == "play" and m.frames < 24 then
      UI.rainbow("GO!", cx, cy - 8, 8, self.t, "center", 255 * (1 - m.frames / 24))
    end
  end
end

function Versus:draw_round_over()
  local m = self.match
  if m.state ~= "over" and m.state ~= "done" then return end
  local k = U.ease_out_back(math.min(1, m.timer / 20))
  for i = 1, 2 do
    local f = self.fields[i]
    local cx, cy = f.x + f.w / 2, f.y + f.h * 0.38
    if m.round_winner == 0 then
      UI.outline("DRAW", cx, cy, 6 * k, "center", UI.GRAY)
    elseif m.round_winner == i then
      UI.rainbow("WIN!", cx, cy + math.sin(self.t * 0.1) * 6, 7 * k, self.t, "center")
    elseif m.timer > 30 or m.state == "done" then
      UI.outline("LOSE", cx, cy, 6, "center", { 170, 170, 210 })
    end
  end
end

function Versus:draw_results()
  local m, r = self.match, self.results
  local champ = m:champion()
  gfx.color(0, 0, 0, math.min(160, r.t * 8))
  gfx.rect(0, 0, 1280, 720)
  if r.t < 10 then return end
  UI.panel(320, 130, 640, 480)
  local me = self.cfg.kind == "online" and self.cfg.local_player or (self.cfg.kind == "cpu" and 1 or nil)
  local title
  if me then title = champ == me and "YOU WIN!" or "YOU LOSE..."
  else title = self.names[champ] .. " WINS!" end
  local tscale = #title > 12 and 4 or 5
  if not me or champ == me then UI.rainbow(title, 640, 166, tscale, self.t, "center")
  else UI.outline(title, 640, 166, tscale, "center", { 170, 170, 220 }) end
  Char.draw(self.chars[champ], 400, 214, 120, 120, "win", self.t, false)
  local rows = {
    { "ROUNDS", m.wins[1], m.wins[2] },
    { "BEST CHAIN", self.totals[1].chain, self.totals[2].chain },
    { "NUISANCE SENT", self.totals[1].sent, self.totals[2].sent },
    { "TOTAL SCORE", self.totals[1].score, self.totals[2].score },
  }
  UI.text("1P", 740, 244, 2, "center", UI.P1)
  UI.text("2P", 880, 244, 2, "center", UI.P2)
  for k, row in ipairs(rows) do
    local y = 300 + k * 40
    UI.text(row[1], 360, y, 2, "left", UI.GRAY)
    UI.text(tostring(row[2]), 740, y, 2, "center", UI.WHITE)
    UI.text(tostring(row[3]), 880, y, 2, "center", UI.WHITE)
  end
  if r.want_rematch then
    UI.text(self.peer_rematch and "STARTING..." or "WAITING FOR THE OTHER PLAYER...", 640, 530, 2, "center", UI.YELLOW)
  else
    UI.menu(self:result_items(), r.sel, 640, 516, self.t, { scale = 3, gap = 40 })
  end
end

function Versus:draw_overlays()
  if self.paused then
    gfx.color(0, 0, 0, 150)
    gfx.rect(0, 0, 1280, 720)
    UI.panel(420, 200, 440, 320)
    UI.outline("PAUSED", 640, 230, 5, "center", UI.YELLOW)
    UI.menu(PAUSE_ITEMS, self.paused.sel, 640, 316, self.t, { scale = 3, gap = 48 })
  end
  if self.leave_confirm and not self.net_error then
    UI.panel(390, 300, 500, 120)
    UI.text("LEAVE THE MATCH?", 640, 326, 3, "center", UI.YELLOW)
    UI.text("Z/ENTER: LEAVE    ESC: KEEP PLAYING", 640, 372, 2, "center", UI.WHITE)
  end
  local err = self.net_error or (self.net and self.net.desync and
    ("DESYNC at frame " .. self.net.desync .. " - please report it with both game versions"))
  if err then
    gfx.color(0, 0, 0, 180)
    gfx.rect(0, 0, 1280, 720)
    UI.panel(240, 260, 800, 200)
    UI.outline(self.net_error and "DISCONNECTED" or "DESYNC", 640, 290, 4, "center", { 255, 120, 120 })
    UI.text(tostring(err):upper(), 640, 360, 2, "center", UI.WHITE)
    UI.text("PRESS Z / ENTER", 640, 410, 2, "center", UI.DIM)
  end
end

function Versus:draw()
  self.stage:draw()
  self:draw_header()
  for _, f in ipairs(self.fields) do
    f:draw_tray()
    f:draw()
    f:draw_score()
  end
  self.fields[1]:draw_next(NEXT_X[1], FIELD_Y)
  self.fields[2]:draw_next(NEXT_X[2], FIELD_Y)
  self:draw_center()
  self.fx:draw()
  self:draw_ready()
  self:draw_round_over()
  if self.results then self:draw_results() end
  self:draw_overlays()
end

return Versus
