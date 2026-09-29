-- Settings screen (+ controls reference page).
-- SPDX-License-Identifier: GPL-2.0-or-later
local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Content = require "core.content"
local AI = require "puyo.ai"
local UI = require "view.ui"
local Skin = require "view.skin"
local Backdrop = require "view.backdrop"

local SettingsScene = {}
SettingsScene.__index = SettingsScene

local function skin_choices()
  local list = { "character" }
  for _, d in ipairs(Content.list("skins")) do list[#list + 1] = d.id end
  return list
end

local ITEMS = {
  { key = "skin", label = "PUYO SKIN", choices = skin_choices,
    fmt = function(v) if v == "character" then return "BY CHARACTER" end local d = Content.get("skins", v); return d and d.name:upper() or v end },
  { key = "colors", label = "COLORS", min = 3, max = 5 },
  { key = "hard_drop", label = "HARD DROP (UP)", bool = true },
  { key = "ghost", label = "LANDING GHOST", bool = true },
  { key = "music", label = "MUSIC VOLUME", min = 0, max = 10 },
  { key = "sfx", label = "SFX VOLUME", min = 0, max = 10 },
  { key = "net_delay", label = "ONLINE INPUT DELAY", min = 0, max = 8 },
  { key = "fullscreen", label = "FULLSCREEN", bool = true },
  { label = "CONTROLS", action = "controls" },
  { label = "BACK", action = "back" },
}

function SettingsScene.new()
  return setmetatable({ t = 0, sel = 1, page = "list" }, SettingsScene)
end

local function value_text(it)
  local v = Settings.data[it.key]
  if it.bool then return v and "ON" or "OFF" end
  if it.fmt then return it.fmt(v) end
  return tostring(v)
end

function SettingsScene:change(it, dir)
  local d = Settings.data
  if it.bool then
    d[it.key] = not d[it.key]
  elseif it.choices then
    local list = it.choices()
    local i = 1
    for k, v in ipairs(list) do if v == d[it.key] then i = k end end
    d[it.key] = list[(i - 1 + dir) % #list + 1]
    UI.skin = Skin.get(d.skin)
  else
    local v = d[it.key] + dir
    if v < it.min then v = it.max elseif v > it.max then v = it.min end
    d[it.key] = v
  end
  Settings.apply()
  Sound.play("menu_move")
end

function SettingsScene:back()
  Settings.save()
  Sound.play("menu_back")
  Scene.go(require("scenes.title").new(6))
end

function SettingsScene:update()
  self.t = self.t + 1
  Backdrop.update()
  local m = Controls.menu
  if self.page == "controls" then
    if m.pressed.confirm or m.pressed.back then
      self.page = "list"
      Sound.play("menu_back")
    end
    return
  end
  if m:rep("up") then self.sel = (self.sel - 2) % #ITEMS + 1; Sound.play("menu_move") end
  if m:rep("down") then self.sel = self.sel % #ITEMS + 1; Sound.play("menu_move") end
  local it = ITEMS[self.sel]
  if it.key then
    if m:rep("left") then self:change(it, -1) end
    if m:rep("right") then self:change(it, 1) end
    if m.pressed.confirm then self:change(it, 1) end
  elseif m.pressed.confirm then
    if it.action == "controls" then
      self.page = "controls"
      Sound.play("menu_ok")
    else
      return self:back()
    end
  end
  if m.pressed.back then self:back() end
end

function SettingsScene:draw_controls()
  UI.panel(170, 70, 940, 590)
  UI.outline("CONTROLS", 640, 96, 4, "center", UI.YELLOW)
  local y = 160
  for _, sec in ipairs(Controls.HELP) do
    UI.text(sec[1], 220, y, 2, "left", UI.P2)
    y = y + 26
    for _, line in ipairs(sec[2]) do
      UI.text(line, 250, y, 2, "left", UI.WHITE)
      y = y + 24
    end
    y = y + 12
  end
  UI.text("PRESS Z / ENTER TO GO BACK", 640, 620, 2, "center", UI.DIM)
end

function SettingsScene:draw()
  Backdrop.draw(0.3)
  if self.page == "controls" then return self:draw_controls() end
  UI.outline("SETTINGS", 640, 44, 5, "center", UI.YELLOW)
  UI.panel(250, 110, 780, 540)
  for k, it in ipairs(ITEMS) do
    local y = 140 + (k - 1) * 48
    local on = k == self.sel
    local col = on and UI.YELLOW or UI.WHITE
    if on then
      gfx.color(255, 255, 255, 22)
      gfx.rect(270, y - 10, 740, 40)
    end
    if it.key then
      UI.text(it.label, 300, y, 3, "left", col)
      local v = value_text(it)
      UI.text(on and ("\001 " .. v .. " \002") or v, 980, y, 3, "right", on and UI.YELLOW or UI.GRAY)
    else
      UI.text(it.label, 640, y, 3, "center", col)
    end
  end
  if ITEMS[self.sel].key == "skin" and UI.skin then
    for v = 1, 5 do UI.skin:puyo(v, 1100, 150 + (v - 1) * 56, 48, 0, "open") end
  end
  UI.text("\003\004 SELECT    \001\002 CHANGE    X / ESC  SAVE & BACK", 640, 676, 2, "center", UI.DIM)
end

return SettingsScene
