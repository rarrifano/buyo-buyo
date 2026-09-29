-- Online lobby: show your connection codes, enter your friend's, connect.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Nothing here talks to a game server: the session sends UDP packets
-- straight to the other player. STUN (a public "what's my address" echo)
-- is only used to show you an internet code.
local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Session = require "net.session"
local Code = require "net.code"
local UI = require "view.ui"
local Backdrop = require "view.backdrop"

local Online = {}
Online.__index = Online

local ROWS = { "code", "connect", "copy", "delay", "back" }

-- opts: connect = "code or ip:port", bot = level, sim = {...}, no_stun, quit_at_end, port
function Online.new(opts)
  opts = opts or {}
  local o = setmetatable({ t = 0, sel = 1, text = "", opts = opts, status = "WAITING FOR A FRIEND..." }, Online)
  local s, err = Session.new { port = opts.port or Settings.data.net_port, name = Settings.data.name, sim = opts.sim }
  if not s then
    o.error = "cannot open a UDP port: " .. tostring(err)
  else
    o.session = s
    s:wait()
    if not opts.no_stun then s:start_stun() end
  end
  if opts.connect then
    o.text = opts.connect
    o:connect()
  end
  return o
end

function Online:enter()
  sys.text_input(true)
end

function Online:leave()
  sys.text_input(false)
end

function Online:connect()
  if not self.session then return end
  local a, b, c = Code.parse(self.text, Session.DEFAULT_PORT)
  if not a then
    self.status = "THAT DOES NOT LOOK LIKE A CODE OR IP:PORT"
    Sound.play("menu_back")
    return
  end
  if c == "resolve" then
    self.resolving = { res = net.resolve(a), port = b, host = a }
    self.status = "LOOKING UP " .. a:upper() .. "..."
  else
    self.session:connect(a, b)
    self.status = "CONNECTING TO " .. self.text:upper() .. "..."
  end
  self.connect_t = self.t
  Sound.play("menu_ok")
end

function Online:text(str)
  if self.sel ~= 1 then return end
  str = str:gsub("[^%w%.%-:]", "")
  if #self.text + #str <= 40 then self.text = self.text .. str end
end

function Online:key(name, down)
  if not down then return end
  if self.sel == 1 and name == "Backspace" then
    self.text = self.text:sub(1, -2)
    self.ate_back = true
  elseif name == "V" and (input.key("Left Ctrl") or input.key("Right Ctrl") or input.key("Left GUI")) then
    local clip = sys.clipboard()
    if clip then self.text = clip:gsub("[^%w%.%-:]", ""):sub(1, 40) end
    self.sel = 1
  end
end

function Online:update()
  self.t = self.t + 1
  Backdrop.update()
  local m = Controls.menu
  local s = self.session
  if self.error or not s then
    if m.pressed.confirm or m.pressed.back then
      Scene.go(require("scenes.title").new(3))
    end
    return
  end
  s:update()
  for _, ev in ipairs(s:poll()) do
    if ev.name == "connected" then
      Sound.play("menu_ok")
      local Select = require "scenes.select"
      Scene.go(Select.new { mode = "online", session = s, bot = self.opts.bot, quit_at_end = self.opts.quit_at_end })
      self.handed_over = true
      return
    elseif ev.name == "error" then
      self.status = tostring(ev.data.msg):upper()
    elseif ev.name == "stun" and not ev.data.ok then
      self.stun_failed = true
    end
  end
  if self.resolving then
    local ip, err = self.resolving.res:result()
    if ip then
      s:connect(ip, self.resolving.port)
      self.status = "CONNECTING TO " .. self.resolving.host:upper() .. "..."
      self.resolving = nil
    elseif ip == false then
      self.status = tostring(err):upper()
      self.resolving = nil
    end
  end
  if s.state == "connecting" and self.connect_t and self.t - self.connect_t > 60 * 8 then
    self.status = "NO ANSWER YET - ASK YOUR FRIEND TO ENTER YOUR CODE TOO"
  end

  -- navigation (letters typed into the code field are handled by text())
  if m:rep("up") and not (self.sel == 1 and input.key("W")) then self.sel = (self.sel - 2) % #ROWS + 1; Sound.play("menu_move") end
  if m:rep("down") and not (self.sel == 1 and input.key("S")) then self.sel = self.sel % #ROWS + 1; Sound.play("menu_move") end
  local row = ROWS[self.sel]
  local enter = input.key("Return") and m.pressed.confirm or (row ~= "code" and m.pressed.confirm)
  if row == "delay" then
    if m:rep("left") and not input.key("A") then Settings.data.net_delay = math.max(0, Settings.data.net_delay - 1); Sound.play("menu_move") end
    if m:rep("right") and not input.key("D") then Settings.data.net_delay = math.min(8, Settings.data.net_delay + 1); Sound.play("menu_move") end
  end
  if enter then
    if row == "code" or row == "connect" then self:connect()
    elseif row == "copy" then
      local codes = s:codes()
      sys.clipboard(codes.public or codes.lan)
      self.status = "YOUR CODE WAS COPIED TO THE CLIPBOARD"
      Sound.play("menu_ok")
    elseif row == "back" then
      s:destroy()
      Settings.save()
      Sound.play("menu_back")
      Scene.go(require("scenes.title").new(3))
    end
  end
  local escape = input.key("Escape") and m.pressed.back
  if escape or (m.pressed.back and row ~= "code" and not self.ate_back) then
    s:destroy()
    Settings.save()
    Sound.play("menu_back")
    Scene.go(require("scenes.title").new(3))
  end
  self.ate_back = false
end

function Online:draw()
  Backdrop.draw(0.3)
  UI.outline("ONLINE", 640, 30, 5, "center", UI.YELLOW)
  UI.text("PEER TO PEER - NO SERVERS - ROLLBACK NETCODE", 640, 84, 2, "center", UI.GRAY)
  UI.panel(170, 116, 940, 540)
  if self.error then
    UI.text(self.error:upper(), 640, 360, 2, "center", { 255, 140, 140 })
    return
  end
  local s = self.session
  local codes = s:codes()
  UI.text("YOUR CODE", 210, 146, 2, "left", UI.GRAY)
  if codes.public then
    UI.outline(codes.public, 640, 176, 5, "center", UI.WHITE)
    UI.text("INTERNET", 1070, 146, 2, "right", UI.DIM)
  elseif self.stun_failed then
    UI.text("INTERNET CODE UNAVAILABLE (OFFLINE?)", 640, 184, 2, "center", UI.DIM)
  else
    UI.text("FINDING YOUR INTERNET ADDRESS...", 640, 184, 2, "center", UI.DIM)
  end
  UI.text("LAN: " .. (codes.lan or "?") .. "   (" .. s.lan_ip .. ":" .. s.port .. ")", 640, 232, 2, "center", UI.GRAY)

  UI.text("Send your code to your friend. One of you types the other's code.", 640, 272, 1.5, "center", UI.DIM)
  UI.text("Doesn't connect? BOTH type each other's code (hole punching).", 640, 292, 1.5, "center", UI.DIM)

  local y0 = 330
  for k, row in ipairs(ROWS) do
    local y = y0 + (k - 1) * 52
    local on = k == self.sel
    local col = on and UI.YELLOW or UI.WHITE
    if row == "code" then
      UI.text("FRIEND'S CODE", 210, y + 6, 2, "left", on and UI.YELLOW or UI.GRAY)
      gfx.color(0, 0, 0, 120)
      gfx.rect(470, y - 4, 600, 36)
      gfx.color(on and 255 or 120, on and 220 or 120, on and 90 or 160)
      gfx.rect_line(470, y - 4, 600, 36, 2)
      local caret = on and (self.t // 20) % 2 == 0 and "_" or ""
      UI.text(self.text:upper() .. caret, 482, y + 2, 3, "left", UI.WHITE)
    elseif row == "connect" then
      UI.text("CONNECT", 640, y, 3, "center", col)
    elseif row == "copy" then
      UI.text("COPY MY CODE", 640, y, 3, "center", col)
    elseif row == "delay" then
      local v = tostring(Settings.data.net_delay) .. " FRAMES"
      UI.text("INPUT DELAY", 210, y + 6, 2, "left", on and UI.YELLOW or UI.GRAY)
      UI.text(on and ("\001 " .. v .. " \002") or v, 1070, y + 6, 2, "right", col)
    elseif row == "back" then
      UI.text("BACK", 640, y, 3, "center", col)
    end
  end
  UI.text(self.status, 640, 612, 2, "center", UI.YELLOW)
  UI.text("Ctrl+V PASTES A CODE.  LAN, VPN (TAILSCALE/ZEROTIER) OR A FORWARDED PORT ALWAYS WORK.", 640, 686, 1.5, "center", UI.DIM)
end

return Online
