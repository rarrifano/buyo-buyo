-- Title screen and main menu.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Content = require "core.content"
local Jukebox = require "core.jukebox"
local Skin = require "view.skin"
local UI = require "view.ui"
local Backdrop = require "view.backdrop"

local Title = {}
Title.__index = Title

local MAIN = { "VS CPU", "2P VERSUS", "ONLINE", "CPU VS CPU", "CONTENT", "SETTINGS", "QUIT" }
local IDLE_DEMO = 60 * 25

function Title.new(sel) return setmetatable({ t = 0, sel = sel or 1, idle = 0 }, Title) end

function Title:enter() Jukebox.play "title" end

function Title:activate(label)
  local Select = require "scenes.select"
  if label == "VS CPU" then
    Sound.play "menu_ok"
    Scene.go(Select.new { mode = "cpu" })
  elseif label == "2P VERSUS" then
    Sound.play "menu_ok"
    Scene.go(Select.new { mode = "2p" })
  elseif label == "CPU VS CPU" then
    Sound.play "menu_ok"
    Scene.go(Select.new { mode = "watch" })
  elseif label == "ONLINE" then
    Sound.play "menu_ok"
    Scene.go(require("scenes.online").new())
  elseif label == "CONTENT" then
    Sound.play "menu_ok"
    Scene.go(require("scenes.browser").new())
  elseif label == "SETTINGS" then
    Sound.play "menu_ok"
    Scene.go(require("scenes.settings").new())
  elseif label == "QUIT" then
    Settings.save()
    sys.quit()
  end
end

function Title:update()
  self.t = self.t + 1
  Backdrop.update()
  local m = Controls.menu
  if m:rep "up" then
    self.sel = (self.sel - 2) % #MAIN + 1
    Sound.play "menu_move"
    self.idle = 0
  end
  if m:rep "down" then
    self.sel = self.sel % #MAIN + 1
    Sound.play "menu_move"
    self.idle = 0
  end
  if m.pressed.confirm then
    self.idle = 0
    self:activate(MAIN[self.sel])
  elseif m.pressed.back and self.sel ~= #MAIN then
    self.idle = 0
    self.sel = #MAIN
    Sound.play "menu_move"
  end
  self.idle = self.idle + 1
  if self.idle > IDLE_DEMO and not Scene.busy() then
    self.idle = 0
    local Versus = require "scenes.versus"
    Scene.go(Versus.new(Versus.demo_config()))
  end
end

function Title:key(_, down)
  if down then self.idle = 0 end
end

function Title:draw()
  Backdrop.draw(0.15)
  local t = self.t
  local drop = math.max(0, 1 - t / 40)
  UI.rainbow("BUYO", 640, 40 - drop * 300, 11, t, "center")
  UI.rainbow("BUYO", 640, 140 - drop * 500, 11, t + 17, "center")
  -- dancing puyos around the logo, drawn with the player's skin
  local skin = UI.skin or Skin.get(Settings.data.skin)
  for k = 1, 8 do
    local side = k <= 4 and -1 or 1
    local j = (k - 1) % 4
    local x = 640 + side * (250 + j * 62)
    local y = 140 + (j % 2) * 40 - math.abs(math.sin(t * 0.08 + k * 0.9)) * 26
    local face = (t + k * 40) % 180 < 8 and "blink"
      or ((t // 120 + k) % 5 == 0 and "happy" or "open")
    skin:puyo((k - 1) % 5 + 1, x, y, 56, 0, face)
  end
  UI.text("VERSUS PUZZLE PLATFORM", 640, 252, 3, "center", UI.GRAY)
  UI.menu(MAIN, self.sel, 640, 306, t, { scale = 3, gap = 44 })
  local n = Content.count()
  UI.text(
    string.format(
      "%d CHARACTERS  %d STAGES  %d SKINS  %d MODES  %d SONGS",
      n.chars,
      n.stages,
      n.skins,
      n.modes,
      n.music
    ),
    640,
    628,
    2,
    "center",
    UI.DIM
  )
  if #Content.errors > 0 then
    UI.text(
      #Content.errors .. " CONTENT ERRORS - SEE CONTENT",
      640,
      654,
      2,
      "center",
      { 255, 140, 140 }
    )
  end
  UI.text("\003\004 SELECT   Z/ENTER OK   X/ESC BACK   F5 RELOAD", 640, 684, 2, "center", UI.DIM)
  local ver = "v" .. sys.version
  if sys.commit and sys.commit ~= "unknown" then ver = ver .. " (" .. sys.commit .. ")" end
  UI.text(ver, 1266, 704, 1.5, "right", UI.DIM)
end

return Title
