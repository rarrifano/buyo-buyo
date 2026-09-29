-- Character select + match options (MUGEN-style select screen).
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Modes: "cpu" (you vs CPU), "2p" (two local players), "watch" (CPU vs CPU),
-- "online" (you vs a remote player; the lobby state is synced via Session).
local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Content = require "core.content"
local Jukebox = require "core.jukebox"
local AI = require "puyo.ai"
local UI = require "view.ui"
local Char = require "view.char"
local Backdrop = require "view.backdrop"

local Select = {}
Select.__index = Select

local CELL, GAP, COLS, ROWS_VISIBLE = 84, 10, 12, 2
local GRID_Y = 520

local function index_of(list, id)
  for i, d in ipairs(list) do
    if d.id == id then return i end
  end
  return nil
end

-- opts: mode, session (online), bot (auto-pick + CPU input, for tests), quit_at_end
function Select.new(opts)
  local s = setmetatable({ opts = opts, t = 0, step = "chars", ctl = {}, start_t = 0 }, Select)
  s.chars = Content.list "chars"
  s.ncells = #s.chars + 1 -- last cell = random
  s.modes = Content.list "modes"
  s.stages = Content.list "stages"
  s.songs = Content.list "music"
  local st = Settings.data
  s.slots = {
    { cursor = index_of(s.chars, st.char1) or 1, locked = false },
    { cursor = index_of(s.chars, st.char2) or math.min(2, #s.chars), locked = false },
  }
  local mode = opts.mode
  if mode == "cpu" then
    s.slots[1].kind, s.slots[2].kind = "human", "cpu"
  elseif mode == "2p" then
    s.slots[1].kind, s.slots[2].kind = "human", "human"
  elseif mode == "watch" then
    s.slots[1].kind, s.slots[2].kind = "cpu", "cpu"
  else
    s.me = opts.session:is_host() and 1 or 2
    s.slots[s.me].kind, s.slots[3 - s.me].kind = "human", "remote"
    s.slots[3 - s.me].cursor = 0
  end
  s.opt = {
    mode = index_of(s.modes, st.mode) or 1,
    stage = 0,
    music = 0,
    first_to = st.first_to,
    level1 = st.cpu_level,
    level2 = st.cpu_level,
  }
  s.opt_sel = 1
  return s
end

function Select:enter()
  if self.opts.mode == "2p" then
    self.ctl[1] = Controls.register("p1", { 1 })
    self.ctl[2] = Controls.register("p2", { 2 })
  end
  Jukebox.play("select", "title")
end

function Select:leave()
  for _, c in pairs(self.ctl) do
    Controls.unregister(c)
  end
end

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

function Select:char_at(i) return self.chars[i] end

-- which slot the shared controller is picking for (single-controller modes)
function Select:active_slot()
  if self.opts.mode == "online" then return self.me end
  if self.opts.mode == "2p" then return nil end
  if not self.slots[1].locked then return 1 end
  if not self.slots[2].locked then return 2 end
  return nil
end

function Select:option_rows()
  local rows = { "mode", "stage", "music", "first_to" }
  if self.opts.mode == "cpu" then rows[#rows + 1] = "level2" end
  if self.opts.mode == "watch" then
    rows[#rows + 1] = "level1"
    rows[#rows + 1] = "level2"
  end
  rows[#rows + 1] = "start"
  return rows
end

function Select:can_edit_options() return self.opts.mode ~= "online" or self.me == 1 end

function Select:move_cursor(slot, dx, dy)
  local n = self.ncells
  local c = slot.cursor
  if dx ~= 0 then c = (c - 1 + dx) % n + 1 end
  if dy ~= 0 then
    local nc = c + dy * COLS
    if nc >= 1 and nc <= n then c = nc end
  end
  if c ~= slot.cursor then
    slot.cursor = c
    Sound.play "menu_move"
  end
end

function Select:lock(slot)
  if slot.locked then return end
  local c = slot.cursor
  if c > #self.chars then c = math.random(1, #self.chars) end
  slot.char = self.chars[c] and self.chars[c].id
  slot.locked = true
  Sound.play "menu_ok"
  local def = self.chars[c]
  if def then Char.voice(def, "start", 1, 0) end
end

function Select:unlock(slot)
  if slot.locked then
    slot.locked = false
    Sound.play "menu_back"
    return true
  end
  return false
end

------------------------------------------------------------------------
-- update
------------------------------------------------------------------------

function Select:update_chars()
  local mode = self.opts.mode
  if mode == "2p" then
    for i = 1, 2 do
      local c, slot = self.ctl[i], self.slots[i]
      if not slot.locked then
        if c:rep "left" then self:move_cursor(slot, -1, 0) end
        if c:rep "right" then self:move_cursor(slot, 1, 0) end
        if c:rep "up" then self:move_cursor(slot, 0, -1) end
        if c:rep "down" then self:move_cursor(slot, 0, 1) end
        if c.pressed.rot_r or c.pressed.rot_l then self:lock(slot) end
      elseif c.pressed.rot_l then
        self:unlock(slot)
      end
    end
    local m = Controls.menu
    if m.pressed.back and not self.slots[1].locked and not self.slots[2].locked then
      return self:quit()
    end
    if m.pressed.confirm then
      for i = 1, 2 do
        if not self.slots[i].locked then return self:lock(self.slots[i]) end
      end
    end
  else
    local m = Controls.menu
    local a = self:active_slot()
    if a then
      local slot = self.slots[a]
      if m:rep "left" then self:move_cursor(slot, -1, 0) end
      if m:rep "right" then self:move_cursor(slot, 1, 0) end
      if m:rep "up" then self:move_cursor(slot, 0, -1) end
      if m:rep "down" then self:move_cursor(slot, 0, 1) end
      if m.pressed.confirm and not slot.locked then self:lock(slot) end
    end
    if m.pressed.back then
      if mode == "online" then
        if not self:unlock(self.slots[self.me]) then return self:quit() end
      elseif not (self:unlock(self.slots[2]) or self:unlock(self.slots[1])) then
        return self:quit()
      end
    end
  end
  if self.slots[1].locked and self.slots[2].locked then
    self.step = "options"
    self.opt_sel = #self:option_rows()
  end
end

function Select:change_option(key, dir)
  local o = self.opt
  if key == "mode" then
    o.mode = (o.mode - 1 + dir) % math.max(1, #self.modes) + 1
  elseif key == "stage" then
    o.stage = (o.stage + dir) % (#self.stages + 1)
  elseif key == "music" then
    o.music = (o.music + dir) % (#self.songs + 1)
  elseif key == "first_to" then
    o.first_to = (o.first_to - 1 + dir) % 5 + 1
  elseif key == "level1" then
    o.level1 = (o.level1 - 1 + dir) % #AI.LEVELS + 1
  elseif key == "level2" then
    o.level2 = (o.level2 - 1 + dir) % #AI.LEVELS + 1
  end
  Sound.play "menu_move"
end

function Select:update_options()
  local m = Controls.menu
  local rows = self:option_rows()
  if m.pressed.back then
    self.step = "chars"
    if self.opts.mode == "online" then
      self:unlock(self.slots[self.me])
    else
      self:unlock(self.slots[2])
    end
    return
  end
  if not self:can_edit_options() then return end
  if m:rep "up" then
    self.opt_sel = (self.opt_sel - 2) % #rows + 1
    Sound.play "menu_move"
  end
  if m:rep "down" then
    self.opt_sel = self.opt_sel % #rows + 1
    Sound.play "menu_move"
  end
  local key = rows[self.opt_sel]
  if key ~= "start" then
    if m:rep "left" then self:change_option(key, -1) end
    if m:rep "right" then self:change_option(key, 1) end
  elseif m.pressed.confirm then
    self:start()
  end
end

-- online: exchange lobby state and handle START / ACK
function Select:update_online()
  local s = self.opts.session
  s:update()
  for _, ev in ipairs(s:poll()) do
    if ev.name == "lobby" then
      local d, r = ev.data, self.slots[3 - self.me]
      r.cursor = math.tointeger(d.cursor) or 0
      r.locked = d.locked == true
      r.char, r.char_name, r.char_color = d.char, d.char_name, d.char_color
      if d.hard_drop ~= nil then self.remote_hard_drop = d.hard_drop == true end
      if self.me == 2 and type(d.opt) == "table" then self.remote_opt = d.opt end
    elseif ev.name == "start" and self.me == 2 then
      self:accept_start(ev.data)
      return
    elseif ev.name == "start_ack" and self.me == 1 and self.pending_start then
      self:launch(self.pending_start)
      return
    elseif ev.name == "disconnected" or ev.name == "error" then
      self.error = ev.data.reason or ev.data.msg
    end
  end
  if self.t % 6 == 0 then
    local me = self.slots[self.me]
    local c = me.cursor <= #self.chars and self.chars[me.cursor] or nil
    local shown = Content.get("chars", me.char) or c
    local msg = {
      cursor = me.cursor,
      locked = me.locked,
      char = me.char or (c and c.id),
      char_name = shown and shown.name or "?",
      char_color = shown and shown.color,
      hard_drop = Settings.data.hard_drop,
    }
    if self.me == 1 then msg.opt = self:resolved_options() end
    s:send_lobby(msg)
  end
  if self.pending_start and self.t - self.start_t > 20 then
    self.start_t = self.t
    s:send_start(self.pending_start.wire)
  end
end

-- bots (headless netplay tests): pick a random character and start
function Select:update_auto()
  local me = self.me or 1
  if self.t == 40 and not self.slots[me].locked then
    self.slots[me].cursor = self.ncells
    self:lock(self.slots[me])
  end
  if self.step == "options" and me == 1 and not self.pending_start and self.t > 70 then
    self:start()
  end
end

function Select:update()
  self.t = self.t + 1
  Backdrop.update()
  if self.opts.bot and self.opts.mode == "online" and not self.error then self:update_auto() end
  if self.opts.mode == "online" then
    if self.error then
      if Controls.menu.pressed.confirm or Controls.menu.pressed.back then return self:quit() end
      return
    end
    self:update_online()
    if Scene.busy() then return end
  end
  if self.step == "chars" then
    self:update_chars()
  else
    self:update_options()
  end
end

------------------------------------------------------------------------
-- starting the match
------------------------------------------------------------------------

-- the options as ids (what gets sent to the guest / used for the match)
function Select:resolved_options()
  local o = self.opt
  local mode = self.modes[o.mode]
  return {
    mode = mode and mode.id,
    mode_hash = mode and mode.hash,
    mode_name = mode and mode.name,
    stage = o.stage > 0 and self.stages[o.stage].id or "auto",
    music = o.music > 0 and self.songs[o.music].id or "auto",
    first_to = o.first_to,
    level1 = o.level1,
    level2 = o.level2,
  }
end

function Select:build_config(o, seed)
  local cfg = {
    kind = self.opts.mode,
    seed = seed,
    mode_id = o.mode,
    mode_hash = o.mode_hash,
    first_to = o.first_to,
    stage_id = o.stage,
    music_id = o.music,
    colors = Settings.data.colors,
    players = {},
    net_bot = self.opts.bot,
    quit_at_end = self.opts.quit_at_end,
  }
  for i = 1, 2 do
    local slot = self.slots[i]
    local p = { char = slot.char, char_name = slot.char_name, char_color = slot.char_color }
    p.cpu = slot.kind == "cpu"
    p.remote = slot.kind == "remote"
    p.level = i == 1 and o.level1 or o.level2
    p.hard_drop = Settings.data.hard_drop
    cfg.players[i] = p
  end
  if cfg.stage_id == "auto" then
    local c2 = Content.get("chars", cfg.players[2].char)
    cfg.stage_id = c2 and Content.get("stages", c2.stage) and c2.stage or "default"
  end
  return cfg
end

function Select:start()
  local o = self:resolved_options()
  local st = Settings.data
  st.char1, st.char2 = self.slots[1].char, self.slots[2].char
  st.mode, st.first_to = o.mode, o.first_to
  st.cpu_level = self.opts.mode == "watch" and o.level1 or o.level2
  Settings.save()
  local seed = (os.time() * 1000 + math.floor(sys.time() * 1000)) & 0x7fffffff
  local cfg = self:build_config(o, seed)
  if self.opts.mode == "online" then
    cfg.players[1].hard_drop = st.hard_drop
    cfg.players[2].hard_drop = self.remote_hard_drop ~= false
    cfg.delay = st.net_delay
    self.pending_start = { cfg = cfg, wire = cfg }
    self.start_t = self.t
    self.opts.session:send_start(cfg)
    return
  end
  self:launch { cfg = cfg }
end

-- guest: validate the host's START and go
function Select:accept_start(cfg)
  local mode = Content.get("modes", cfg.mode_id)
  if not mode or mode.hash ~= cfg.mode_hash then
    self.error = "you don't have the same '" .. tostring(cfg.mode_id) .. "' mode as the host"
    return
  end
  self.opts.session:send_start_ack()
  cfg.players[1].remote, cfg.players[2].remote = true, false
  self:launch { cfg = cfg }
end

function Select:launch(p)
  local cfg = p.cfg
  cfg.net_bot, cfg.quit_at_end = self.opts.bot, self.opts.quit_at_end
  if self.opts.mode == "online" then
    cfg.kind = "online"
    cfg.session = self.opts.session
    cfg.local_player = self.me
    cfg.players[self.me].remote = false
    cfg.players[3 - self.me].remote = true
  end
  local Versus = require "scenes.versus"
  Scene.go(Versus.new(cfg))
end

function Select:quit()
  if self.opts.session then self.opts.session:destroy() end
  Sound.play "menu_back"
  Scene.go(require("scenes.title").new())
end

------------------------------------------------------------------------
-- drawing
------------------------------------------------------------------------

function Select:slot_def(i)
  local slot = self.slots[i]
  if slot.char then
    local d = Content.get("chars", slot.char)
    if d then return d end
  end
  if slot.kind == "remote" then
    if slot.char and not Content.get("chars", slot.char) then
      return { id = "?", name = slot.char_name or "?", color = slot.char_color or { 200, 200, 200 } }
    end
  end
  return self.chars[slot.cursor]
end

function Select:draw_portrait(i)
  local x = i == 1 and 40 or 880
  local def = self:slot_def(i)
  local slot = self.slots[i]
  local col = i == 1 and UI.P1 or UI.P2
  UI.panel(x, 70, 360, 420, 200, col)
  if def then
    local mood = slot.locked and "happy" or "idle"
    Char.draw(def, x + 10, 80, 340, 340, mood, self.t, i == 2)
    UI.text(def.name:upper(), x + 180, 426, 3, "center", def.color or UI.WHITE)
    UI.text("by " .. (def.author or "?"), x + 180, 458, 1.5, "center", UI.DIM)
  elseif slot.cursor == self.ncells then
    UI.outline("?", x + 180, 190, 14, "center", UI.YELLOW)
    UI.text("RANDOM", x + 180, 426, 3, "center", UI.YELLOW)
  end
  local who = slot.kind == "cpu" and "CPU"
    or (slot.kind == "remote" and "REMOTE" or (i == 1 and "1P" or "2P"))
  UI.text(who, x + 16, 84, 2, "left", col)
  if slot.locked then UI.text("READY!", x + 344, 84, 2, "right", UI.YELLOW) end
end

function Select:draw_grid()
  local n = self.ncells
  local cols = math.min(COLS, n)
  local rows = math.ceil(n / cols)
  local focus = self.slots[self:active_slot() or 1].cursor
  local first_row =
    math.max(0, math.min(rows - ROWS_VISIBLE, (math.max(focus, 1) - 1) // cols - ROWS_VISIBLE + 1))
  local width = cols * CELL + (cols - 1) * GAP
  local x0 = 640 - width / 2
  for k = 1, n do
    local r = (k - 1) // cols - first_row
    if r >= 0 and r < ROWS_VISIBLE then
      local x = x0 + ((k - 1) % cols) * (CELL + GAP)
      local y = GRID_Y + r * (CELL + GAP)
      gfx.color(20, 16, 50, 220)
      gfx.rect(x, y, CELL, CELL)
      local def = self.chars[k]
      if def then
        Char.draw(def, x + 4, y + 4, CELL - 8, CELL - 8, "idle", self.t)
      else
        UI.outline("?", x + CELL / 2, y + 18, 6, "center", UI.YELLOW)
      end
      for i = 1, 2 do
        local slot = self.slots[i]
        if slot.cursor == k and (slot.kind ~= "remote" or slot.cursor > 0) then
          local col = i == 1 and UI.P1 or UI.P2
          local pulse = slot.locked and 255 or (160 + 95 * math.abs(math.sin(self.t * 0.12)))
          gfx.color(col[1], col[2], col[3], pulse)
          gfx.rect_line(
            x - 4 + (i - 1) * 3,
            y - 4 + (i - 1) * 3,
            CELL + 8 - (i - 1) * 6,
            CELL + 8 - (i - 1) * 6,
            4
          )
          UI.text(
            i == 1 and "1P" or "2P",
            x + (i == 1 and 4 or CELL - 4),
            y + CELL - 16,
            1.5,
            i == 1 and "left" or "right",
            col
          )
        end
      end
    end
  end
  if rows > ROWS_VISIBLE then
    UI.text(
      string.format("%d/%d", first_row + 1, rows - ROWS_VISIBLE + 1),
      640 + width / 2,
      GRID_Y - 20,
      1.5,
      "right",
      UI.DIM
    )
  end
end

local function name_of(list, idx, auto)
  if idx == 0 then return auto end
  return list[idx] and list[idx].name or "?"
end

function Select:draw_options()
  local o = self.opt
  local ro = (self.opts.mode == "online" and self.me == 2) and self.remote_opt or nil
  UI.panel(420, 90, 440, 400)
  UI.outline("MATCH", 640, 108, 4, "center", UI.YELLOW)
  local rows = self:option_rows()
  local labels = {
    mode = { "MODE", ro and ro.mode_name or name_of(self.modes, o.mode, "?") },
    stage = { "STAGE", ro and ro.stage or name_of(self.stages, o.stage, "AUTO") },
    music = { "MUSIC", ro and ro.music or name_of(self.songs, o.music, "AUTO") },
    first_to = { "FIRST TO", tostring(ro and ro.first_to or o.first_to) },
    level1 = { "1P CPU", AI.LEVELS[o.level1].name },
    level2 = { self.opts.mode == "watch" and "2P CPU" or "CPU", AI.LEVELS[o.level2].name },
    start = { "START", nil },
  }
  for k, key in ipairs(rows) do
    local y = 160 + (k - 1) * 44
    local on = k == self.opt_sel and self:can_edit_options()
    local l = labels[key]
    if key == "start" then
      UI.text(l[1], 640, y + 12, 4, "center", on and UI.YELLOW or UI.WHITE)
    else
      UI.text(l[1], 440, y, 2, "left", on and UI.YELLOW or UI.GRAY)
      local v = tostring(l[2]):upper()
      if #v > 18 then v = v:sub(1, 17) .. "." end
      UI.text(
        on and ("\001 " .. v .. " \002") or v,
        840,
        y,
        2,
        "right",
        on and UI.YELLOW or UI.WHITE
      )
    end
  end
  local mode = self.modes[o.mode]
  if mode and mode.description and not ro then
    UI.paragraph(mode.description, 640, 424, 34, 1.5, "center", UI.DIM, 3)
  end
  if not self:can_edit_options() then
    UI.text("THE HOST IS CHOOSING...", 640, 440, 2, "center", UI.GRAY)
  end
end

function Select:draw()
  Backdrop.draw(0.25)
  local title = ({ cpu = "VS CPU", ["2p"] = "2P VERSUS", watch = "CPU VS CPU", online = "ONLINE" })[self.opts.mode]
  UI.outline(title, 640, 22, 4, "center", UI.YELLOW)
  self:draw_portrait(1)
  self:draw_portrait(2)
  if self.step == "options" then
    self:draw_options()
  else
    UI.outline("VS", 640, 250, 8, "center", { 255, 230, 120 }, { 70, 20, 60 })
    local a = self:active_slot()
    local hint
    if self.opts.mode == "2p" then
      hint = "1P: WASD + G   2P: ARROWS + ."
    elseif a == 2 and self.opts.mode == "cpu" then
      hint = "CHOOSE YOUR OPPONENT"
    else
      hint = "CHOOSE YOUR CHARACTER"
    end
    UI.text(hint, 640, 360, 2, "center", UI.GRAY)
  end
  self:draw_grid()
  if self.opts.mode == "online" then
    local s = self.opts.session
    UI.text(
      string.format("VS %s   PING %dms", (s.peer_name or "?"):upper(), math.floor(s.rtt * 1000)),
      640,
      694,
      2,
      "center",
      UI.DIM
    )
  end
  if self.error then
    gfx.color(0, 0, 0, 180)
    gfx.rect(0, 0, 1280, 720)
    UI.panel(290, 260, 700, 200)
    UI.outline("DISCONNECTED", 640, 290, 4, "center", { 255, 120, 120 })
    UI.text(tostring(self.error):upper(), 640, 360, 2, "center", UI.WHITE)
    UI.text("PRESS Z / ENTER", 640, 410, 2, "center", UI.DIM)
  end
end

return Select
