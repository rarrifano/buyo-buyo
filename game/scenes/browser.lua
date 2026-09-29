-- Content browser: see everything that is installed, preview it, find
-- errors, and start your own content from a copy of any item.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Scene = require "core.scene"
local Controls = require "core.controls"
local Sound = require "core.sound"
local Content = require "core.content"
local Jukebox = require "core.jukebox"
local Skin = require "view.skin"
local Char = require "view.char"
local UI = require "view.ui"
local Backdrop = require "view.backdrop"

local Browser = {}
Browser.__index = Browser

local TABS = { "chars", "stages", "skins", "modes", "music", "errors" }
local ACTIONS =
  { "REMIX INTO MY MODS", "EXPORT SKIN SHEET", "OPEN MODS FOLDER", "RELOAD ALL", "BACK" }
local VISIBLE = 11

function Browser.new()
  return setmetatable(
    { t = 0, tab = 1, sel = 1, scroll = 0, pane = "list", act = 1, msg = "" },
    Browser
  )
end

function Browser:enter() Jukebox.play "title" end

function Browser:items()
  local kind = TABS[self.tab]
  if kind == "errors" then return Content.errors end
  return Content.list(kind)
end

function Browser:current()
  local list = self:items()
  return list[self.sel]
end

-- copy a folder tree (used to "remix" an item into the user's mods)
local function copy_tree(src, dst)
  sys.mkdir(dst)
  for _, e in ipairs(sys.list_dir(src)) do
    local a, b = src .. "/" .. e.name, dst .. "/" .. e.name
    if e.dir then
      copy_tree(a, b)
    else
      local data = sys.read_file(a)
      if data then sys.write_file(b, data) end
    end
  end
end

function Browser:remix(def)
  local mods = Content.ensure_user_dir()
  if not mods then
    self.msg = "NO USER FOLDER AVAILABLE"
    return
  end
  local base = mods .. "/" .. def.kind .. "/my_" .. def.id
  local dst, n = base, 1
  while sys.exists(dst) do
    n = n + 1
    dst = base .. "_" .. n
  end
  if def.kind == "music" and def.folder:match "/music$" then
    -- single-file song: make it a folder
    sys.mkdir(dst)
    sys.write_file(dst .. "/song.lua", sys.read_file(def.source) or "")
  else
    copy_tree(def.folder, dst)
  end
  local file = dst .. "/" .. Content.FILE[def.kind]
  local src = sys.read_file(file)
  if src then
    src = src:gsub('name%s*=%s*"([^"]*)"', 'name = "My %1"', 1)
    sys.write_file(file, src)
  end
  self:reload()
  self.msg = "CREATED " .. dst:upper()
  sys.clipboard(dst)
end

function Browser:export_skin(def)
  local mods = Content.ensure_user_dir() or "."
  local ok, sheet = pcall(Skin.sheet, def)
  if not ok then
    self.msg = tostring(sheet):upper()
    return
  end
  local path = mods .. "/skin-" .. def.id .. ".png"
  local saved, err = gfx.save_png(sheet, path)
  self.msg = saved and ("SAVED " .. path:upper()) or tostring(err):upper()
end

function Browser:reload()
  Content.load_all(Content.extra_roots)
  Skin.clear_cache()
  Char.clear_cache()
  UI.skin = Skin.get(require("core.settings").data.skin)
  self.sel = math.min(self.sel, math.max(1, #self:items()))
end

function Browser:update()
  self.t = self.t + 1
  Backdrop.update()
  local m = Controls.menu
  if self.pane == "list" then
    local n = #self:items()
    if m:rep "left" then
      self.tab = (self.tab - 2) % #TABS + 1
      self.sel, self.scroll = 1, 0
      Sound.play "menu_move"
    end
    if m:rep "right" then
      self.tab = self.tab % #TABS + 1
      self.sel, self.scroll = 1, 0
      Sound.play "menu_move"
    end
    if m:rep "up" and n > 0 then
      self.sel = (self.sel - 2) % n + 1
      Sound.play "menu_move"
    end
    if m:rep "down" and n > 0 then
      self.sel = self.sel % n + 1
      Sound.play "menu_move"
    end
    if self.sel <= self.scroll then self.scroll = self.sel - 1 end
    if self.sel > self.scroll + VISIBLE then self.scroll = self.sel - VISIBLE end
    if m.pressed.confirm then
      self.pane = "actions"
      Sound.play "menu_ok"
      local def = self:current()
      if def and def.kind == "music" then
        Jukebox.current = nil
        Jukebox.play(def.id)
      end
    end
    if m.pressed.back then
      Sound.play "menu_back"
      Scene.go(require("scenes.title").new(5))
    end
  else
    if m:rep "up" then
      self.act = (self.act - 2) % #ACTIONS + 1
      Sound.play "menu_move"
    end
    if m:rep "down" then
      self.act = self.act % #ACTIONS + 1
      Sound.play "menu_move"
    end
    if m.pressed.back then
      self.pane = "list"
      Sound.play "menu_back"
      Jukebox.play "title"
    elseif m.pressed.confirm then
      Sound.play "menu_ok"
      local a, def = ACTIONS[self.act], self:current()
      if a == "REMIX INTO MY MODS" then
        if def and def.kind then
          self:remix(def)
        else
          self.msg = "SELECT AN ITEM FIRST"
        end
      elseif a == "EXPORT SKIN SHEET" then
        if def and def.kind == "skins" then
          self:export_skin(def)
        else
          self.msg = "SELECT A SKIN IN THE SKINS TAB"
        end
      elseif a == "OPEN MODS FOLDER" then
        local dir = Content.ensure_user_dir()
        if dir then
          sys.clipboard(dir)
          if not sys.open_url("file://" .. dir) then
            self.msg = "PATH COPIED: " .. dir:upper()
          else
            self.msg = dir:upper()
          end
        end
      elseif a == "RELOAD ALL" then
        self:reload()
        self.msg = "RELOADED - " .. #Content.errors .. " ERRORS"
      else
        self.pane = "list"
      end
    end
  end
end

function Browser:draw_preview(def, x, y)
  local kind = TABS[self.tab]
  if kind == "errors" then
    UI.text((def.kind .. "/" .. def.id):upper(), x, y, 2, "left", { 255, 140, 140 })
    UI.paragraph(def.msg, x, y + 30, 56, 1.5, "left", UI.WHITE, 26)
    return
  end
  UI.text(def.name:upper(), x, y, 3, "left", def.color or UI.YELLOW)
  UI.text("ID " .. def.id .. "   BY " .. def.author:upper(), x, y + 32, 1.5, "left", UI.GRAY)
  UI.text(
    "FROM "
      .. def.root:upper()
      .. (def.overrides and (" (OVERRIDES " .. def.overrides:upper() .. ")") or ""),
    x,
    y + 50,
    1.5,
    "left",
    UI.DIM
  )
  UI.paragraph(def.description or "", x, y + 76, 56, 1.5, "left", UI.WHITE, 3)
  local py = y + 140
  if kind == "chars" then
    for k, mood in ipairs(Char.MOODS) do
      Char.draw(def, x + (k - 1) % 3 * 150, py + (k - 1) // 3 * 150, 140, 140, mood, self.t)
    end
  elseif kind == "skins" then
    local sk = Skin.get(def.id)
    for v = 1, 5 do
      sk:puyo(v, x + 30 + (v - 1) * 70, py + 30, 60, 0, "open")
    end
    -- a connected shape
    local shape = { { 0, 0, 2 | 4 }, { 1, 0, 8 | 4 }, { 0, 1, 1 | 2 }, { 1, 1, 1 | 8 } }
    for _, c in ipairs(shape) do
      sk:puyo(1, x + 50 + c[1] * 60, py + 110 + c[2] * 60, 60, c[3], "happy")
    end
    sk:puyo(6, x + 220, py + 140, 60, 0)
    UI.text(
      "CELL "
        .. def.cell
        .. "  "
        .. (def.sheet and ("SHEET " .. def.sheet:upper()) or "PAINTED BY CODE"),
      x,
      py + 210,
      1.5,
      "left",
      UI.DIM
    )
  elseif kind == "stages" then
    UI.text(#(def.layers or {}) .. " IMAGE LAYERS", x, py, 2, "left", UI.GRAY)
    UI.text((def.draw and "SCRIPTED DRAWING" or "NO SCRIPT"), x, py + 26, 2, "left", UI.GRAY)
    UI.text("MUSIC: " .. tostring(def.music or "default"):upper(), x, py + 52, 2, "left", UI.GRAY)
  elseif kind == "modes" then
    local n = 0
    for k, v in pairs(def.rules or {}) do
      if n < 12 and type(v) ~= "table" then
        UI.text(
          string.format("%s = %s", k, tostring(v)):upper(),
          x,
          py + n * 20,
          1.5,
          "left",
          UI.GRAY
        )
        n = n + 1
      end
    end
    local hooks = {}
    for _, h in ipairs {
      "init",
      "round_start",
      "frame",
      "link",
      "chain_end",
      "pair",
      "garbage",
      "winner",
      "hud",
    } do
      if type(def[h]) == "function" then hooks[#hooks + 1] = h end
    end
    UI.text(
      "HOOKS: " .. (#hooks > 0 and table.concat(hooks, " ") or "none"):upper(),
      x,
      py + 250,
      1.5,
      "left",
      UI.DIM
    )
    UI.text("HASH " .. def.hash, x, py + 270, 1.5, "left", UI.DIM)
  elseif kind == "music" then
    UI.text(
      def.file and ("FILE " .. def.file:upper()) or ("CHIPTUNE " .. tostring(def.bpm) .. " BPM"),
      x,
      py,
      2,
      "left",
      UI.GRAY
    )
    UI.text("PRESS Z TO PLAY", x, py + 30, 2, "left", UI.DIM)
  end
end

function Browser:draw()
  Backdrop.draw(0.35)
  UI.outline("CONTENT", 640, 20, 4, "center", UI.YELLOW)
  -- tabs
  local counts = Content.count()
  for k, tab in ipairs(TABS) do
    local n = tab == "errors" and #Content.errors or counts[tab]
    local label = tab:upper() .. " " .. n
    local x = 110 + (k - 1) * 180
    local on = k == self.tab
    UI.text(
      label,
      x + 80,
      66,
      2,
      "center",
      on and UI.YELLOW or (tab == "errors" and n > 0 and { 255, 140, 140 } or UI.GRAY)
    )
    if on then
      gfx.color(255, 220, 90)
      gfx.rect(x + 10, 88, 140, 3)
    end
  end
  UI.panel(40, 104, 440, 520)
  UI.panel(500, 104, 740, 520)
  local list = self:items()
  if #list == 0 then UI.text("NOTHING HERE", 260, 140, 2, "center", UI.DIM) end
  for i = self.scroll + 1, math.min(#list, self.scroll + VISIBLE) do
    local d = list[i]
    local y = 120 + (i - self.scroll - 1) * 44
    local on = i == self.sel
    if on then
      gfx.color(255, 255, 255, 24)
      gfx.rect(52, y - 6, 416, 38)
    end
    local name = TABS[self.tab] == "errors" and (d.kind .. "/" .. d.id) or d.name
    UI.text(name:upper():sub(1, 24), 64, y, 2, "left", on and UI.YELLOW or UI.WHITE)
    if TABS[self.tab] ~= "errors" and d.root ~= "built-in" then
      UI.text(d.root:upper(), 456, y + 4, 1.5, "right", UI.P2)
    end
  end
  local def = self:current()
  if def then self:draw_preview(def, 530, 130) end
  if self.pane == "actions" then
    gfx.color(0, 0, 0, 150)
    gfx.rect(0, 0, 1280, 720)
    UI.panel(400, 220, 480, 300)
    UI.menu(ACTIONS, self.act, 640, 250, self.t, { scale = 2, gap = 52 })
  end
  UI.text(self.msg, 640, 640, 1.5, "center", UI.YELLOW)
  UI.text(
    "\001\002 TYPE   \003\004 ITEM   Z ACTIONS   X BACK   F5 RELOAD",
    640,
    668,
    1.5,
    "center",
    UI.DIM
  )
  UI.text(
    "YOUR MODS: " .. UI.tail((sys.pref_dir() or "") .. "mods", 80),
    640,
    690,
    1.5,
    "center",
    UI.DIM
  )
end

return Browser
