-- Content system: discovers and loads characters, stages, skins, modes and
-- music from content folders ("packs"), MUGEN style.
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Layout of a content root (see docs/GETTING_STARTED.md):
--   chars/<id>/char.lua      stages/<id>/stage.lua     skins/<id>/skin.lua
--   modes/<id>/mode.lua      music/<id>/song.lua  (or music/<id>.lua)
--
-- Roots, in load order (later ones override items with the same id):
--   1. <install>/content          built-in examples
--   2. <user data>/mods           your own stuff (created on first run)
--   3. --mods DIR                 extra folders given on the command line
--
-- Descriptor files run in a sandbox: no io/os/require/load, file access only
-- through helpers restricted to the item's own folder, and game modes get
-- no math.random (they must be deterministic for netplay).
local Rules = require "puyo.rules"

local Content = {}

Content.KINDS = { "chars", "stages", "skins", "modes", "music" }
Content.FILE = { chars = "char.lua", stages = "stage.lua", skins = "skin.lua", modes = "mode.lua", music = "song.lua" }
Content.API_VERSION = 1

Content.items = {}   -- kind -> id -> def
Content.lists = {}   -- kind -> sorted array of defs
Content.errors = {}  -- { kind=, id=, msg= }
Content.roots = {}

local SAFE_BASE = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber", "tostring",
  "type", "xpcall", "rawequal", "rawlen", "setmetatable", "getmetatable",
}
local SAFE_GFX = {
  "color", "rect", "rect_line", "line", "circle", "draw", "drawq", "stretch",
  "text", "text_width", "blend", "size", "image", "shape",
}

Content.PALETTE = {
  { 255, 76, 92 }, { 70, 214, 100 }, { 70, 130, 255 }, { 255, 210, 50 }, { 186, 96, 255 }, { 205, 212, 232 },
}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

-- FNV-1a 32 of a string, as 8 hex digits
function Content.hash_string(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
  return string.format("%08x", h)
end

local function shallow_copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- resolve a file name relative to an item folder; refuses to escape it
function Content.path(def, name)
  if type(name) ~= "string" or name == "" then return nil, "file name expected" end
  if name:find("..", 1, true) or name:match("^[/\\]") or name:match("^%a:") or not name:match("^[%w_%-%./ ]+$") then
    return nil, "invalid file name '" .. name .. "' (stay inside the item folder)"
  end
  return def.folder .. "/" .. name
end

function Content.report(kind, id, msg)
  for _, e in ipairs(Content.errors) do
    if e.kind == kind and e.id == id and e.msg == msg then return end
  end
  Content.errors[#Content.errors + 1] = { kind = kind, id = id, msg = msg }
  print(string.format("[content] %s/%s: %s", kind, id, msg))
end

-- call a function defined by content; errors are reported and the function
-- is disabled so a broken mod degrades gracefully instead of crashing
function Content.call(def, name, ...)
  local f = def and def[name]
  if type(f) ~= "function" then return nil end
  def._disabled = def._disabled or {}
  if def._disabled[name] then return nil end
  local ok, a, b, c = pcall(f, ...)
  if not ok then
    def._disabled[name] = true
    Content.report(def.kind, def.id, string.format("%s() failed and was disabled: %s", name, tostring(a)))
    return nil
  end
  return a, b, c
end

------------------------------------------------------------------------
-- sandbox
------------------------------------------------------------------------

-- a read-only view of a table (content cannot tamper with shared APIs)
local function readonly(t)
  return setmetatable({}, {
    __index = t,
    __newindex = function() error("this table is read-only", 2) end,
    __metatable = false,
  })
end
Content.readonly = readonly

-- drawing functions content may use (no file access); a fresh read-only
-- proxy per caller so no mod can affect another
local safe_gfx
function Content.sandbox_gfx()
  if not safe_gfx then
    safe_gfx = {}
    for _, k in ipairs(SAFE_GFX) do safe_gfx[k] = gfx[k] end
  end
  return readonly(safe_gfx)
end

local asset_cache = setmetatable({}, { __mode = "v" })

local function make_env(kind, def)
  local env = {}
  for _, k in ipairs(SAFE_BASE) do env[k] = _G[k] end
  env.math = shallow_copy(math)
  env.string = shallow_copy(string)
  env.table = shallow_copy(table)
  env.utf8 = shallow_copy(utf8)
  env.coroutine = shallow_copy(coroutine)
  env._VERSION = _VERSION
  if kind == "modes" then
    env.math.random, env.math.randomseed = nil, nil -- use m.rng in hooks
  end
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    print(string.format("[%s/%s] %s", kind, def.id, table.concat(parts, " ")))
  end
  env.ENGINE = { version = sys.version, api = Content.API_VERSION, platform = sys.platform }
  env.PALETTE = Rules.copy(Content.PALETTE)
  env.RULES = Rules.copy(Rules.DEFAULTS)
  env.SUB = Rules.SUB
  -- file helpers, restricted to this item's folder
  env.asset = function(name)
    local p, err = Content.path(def, name)
    if not p then error(err, 2) end
    return p
  end
  if kind ~= "modes" then
    env.gfx = Content.sandbox_gfx()
    env.load_image = function(name, filter)
      local p, err = Content.path(def, name)
      if not p then error(err, 2) end
      local key = p .. "|" .. tostring(filter)
      if asset_cache[key] then return asset_cache[key] end
      local tex, e = gfx.load(p, filter)
      if not tex then error(e, 2) end
      asset_cache[key] = tex
      return tex
    end
    env.load_canvas = function(name)
      local p, err = Content.path(def, name)
      if not p then error(err, 2) end
      local img, e = gfx.image_load(p)
      if not img then error(e, 2) end
      return img
    end
    env.load_sound = function(name)
      local p, err = Content.path(def, name)
      if not p then error(err, 2) end
      local s, e = audio.load(p)
      if not s then error(e, 2) end
      return s
    end
    env.play_sound = function(sample, vol, pan, pitch) audio.play_sample(sample, vol, pan, pitch) end
    env.synth = function(t) if type(t) == "table" then audio.play(t) end end
  end
  return env
end

------------------------------------------------------------------------
-- validation per kind
------------------------------------------------------------------------

local function color3(c, default)
  if type(c) == "table" and type(c[1]) == "number" and type(c[2]) == "number" and type(c[3]) == "number" then
    return { c[1], c[2], c[3] }
  end
  return default
end

local VALIDATE = {}

function VALIDATE.chars(d)
  d.color = color3(d.color, { 255, 255, 255 })
  if d.portrait ~= nil and type(d.portrait) ~= "string" then return "portrait must be a file name" end
  if d.paint ~= nil and type(d.paint) ~= "function" then return "paint must be a function" end
  if d.moods ~= nil and type(d.moods) ~= "table" then return "moods must be a table of file names" end
  if d.voice ~= nil and type(d.voice) ~= "table" then return "voice must be a table" end
  if d.cpu ~= nil and type(d.cpu) ~= "table" then return "cpu must be a table" end
end

function VALIDATE.stages(d)
  if d.layers ~= nil and type(d.layers) ~= "table" then return "layers must be a list" end
  for _, k in ipairs { "init", "update", "draw" } do
    if d[k] ~= nil and type(d[k]) ~= "function" then return k .. " must be a function" end
  end
end

function VALIDATE.skins(d)
  if type(d.sheet) ~= "string" and type(d.paint) ~= "function" then
    return "a skin needs either sheet = \"file.png\" or a paint(img, cell, api) function"
  end
  d.cell = math.tointeger(d.cell) or 64
  if d.cell < 8 or d.cell > 256 then return "cell must be between 8 and 256" end
end

function VALIDATE.modes(d)
  if d.rules ~= nil and type(d.rules) ~= "table" then return "rules must be a table" end
  for k, v in pairs(d) do
    if type(v) == "function" and not ({ init = 1, round_start = 1, frame = 1, link = 1, chain_end = 1,
      pair = 1, garbage = 1, winner = 1, hud = 1 })[k] then
      return "unknown hook '" .. k .. "' (see docs/MODES.md)"
    end
  end
end

function VALIDATE.music(d)
  if type(d.file) ~= "string" and type(d.channels) ~= "table" then
    return "a song needs file = \"song.ogg\" or chiptune channels = { ... }"
  end
end

------------------------------------------------------------------------
-- loading
------------------------------------------------------------------------

local function load_item(kind, id, folder, file, root)
  local src, err = sys.read_file(file)
  if not src then return Content.report(kind, id, err) end
  -- internal fields (content cannot override them): id kind folder source root hash
  local def = { id = id, kind = kind, folder = folder, source = file, root = root.label }
  local env = make_env(kind, def)
  local chunk, cerr = load(src, "@" .. file, "t", env)
  if not chunk then return Content.report(kind, id, cerr) end
  local ok, result = pcall(chunk)
  if not ok then return Content.report(kind, id, tostring(result)) end
  if type(result) ~= "table" then return Content.report(kind, id, "the file must return a table") end
  for k, v in pairs(result) do
    if def[k] == nil then def[k] = v end
  end
  def.name = type(def.name) == "string" and def.name or id
  def.author = type(def.author) == "string" and def.author or "unknown"
  def.hash = Content.hash_string(src)
  local verr = VALIDATE[kind](def)
  if verr then return Content.report(kind, id, verr) end
  local prev = Content.items[kind][id]
  if prev then def.overrides = prev.root end
  Content.items[kind][id] = def
end

function Content.default_roots(extra)
  local roots = { { path = sys.data_dir() .. "/../content", label = "built-in" } }
  local pref = sys.pref_dir()
  if pref and pref ~= "" then roots[#roots + 1] = { path = pref .. "mods", label = "user" } end
  for _, p in ipairs(extra or {}) do roots[#roots + 1] = { path = p, label = "extra" } end
  return roots
end

-- make sure the user mods folder exists and explains itself
function Content.ensure_user_dir()
  local pref = sys.pref_dir()
  if not pref or pref == "" or sys.headless() then return nil end
  local dir = pref .. "mods"
  if sys.exists(dir) ~= "dir" then
    sys.mkdir(dir)
    for _, k in ipairs(Content.KINDS) do sys.mkdir(dir .. "/" .. k) end
    sys.write_file(dir .. "/README.txt", table.concat({
      "Buyo Buyo user content folder",
      "",
      "Drop content packs here, one folder per item:",
      "  chars/<id>/char.lua    stages/<id>/stage.lua    skins/<id>/skin.lua",
      "  modes/<id>/mode.lua    music/<id>/song.lua",
      "",
      "Items here override built-in items with the same id.",
      "Press F5 in game to reload. The full guide is in docs/ (docs/README.md).",
      "",
    }, "\n"))
  end
  return dir
end

function Content.load_all(extra)
  Content.errors = {}
  for _, k in ipairs(Content.KINDS) do
    Content.items[k] = {}
    Content.lists[k] = {}
  end
  Content.roots = Content.default_roots(extra)
  for _, root in ipairs(Content.roots) do
    if sys.exists(root.path) == "dir" then
      for _, kind in ipairs(Content.KINDS) do
        local dir = root.path .. "/" .. kind
        if sys.exists(dir) == "dir" then
          local entries = sys.list_dir(dir)
          table.sort(entries, function(a, b) return a.name < b.name end)
          for _, e in ipairs(entries) do
            local id, folder, file
            if e.dir then
              id, folder = e.name, dir .. "/" .. e.name
              file = folder .. "/" .. Content.FILE[kind]
              if sys.exists(file) ~= "file" then file = nil end
            elseif kind == "music" and e.name:match("%.lua$") then
              id, folder, file = e.name:gsub("%.lua$", ""), dir, dir .. "/" .. e.name
            end
            if file then
              if id:match("^[%w_%-]+$") then
                load_item(kind, id, folder, file, root)
              else
                Content.report(kind, id, "invalid folder name (use letters, digits, _ and -)")
              end
            end
          end
        end
      end
    end
  end
  for _, k in ipairs(Content.KINDS) do
    local list = {}
    for _, def in pairs(Content.items[k]) do
      if not (def.hidden == true) then list[#list + 1] = def end
    end
    table.sort(list, function(a, b)
      local oa, ob = tonumber(a.order) or 100, tonumber(b.order) or 100
      if oa ~= ob then return oa < ob end
      return a.name:lower() < b.name:lower()
    end)
    Content.lists[k] = list
  end
  -- never leave the platform without a character (e.g. content folder missing)
  if #Content.lists.chars == 0 then
    local stub = { id = "nobody", kind = "chars", name = "Nobody", author = "engine", color = { 230, 230, 240 },
                   folder = ".", source = "", root = "engine", hash = "0" }
    Content.items.chars.nobody = stub
    Content.lists.chars = { stub }
    Content.report("chars", "nobody", "no characters found - install some into " .. (Content.roots[2] and Content.roots[2].path or "mods"))
  end
end

function Content.get(kind, id)
  return id and Content.items[kind] and Content.items[kind][id] or nil
end

function Content.list(kind) return Content.lists[kind] or {} end

-- first item of a kind, preferring `id`
function Content.pick(kind, id)
  return Content.get(kind, id) or Content.list(kind)[1]
end

function Content.count()
  local n = {}
  for _, k in ipairs(Content.KINDS) do n[k] = #Content.list(k) end
  return n
end

-- hash of the simulation code: peers with different versions must not play
function Content.core_hash()
  if Content._core then return Content._core end
  local acc = sys.version
  for _, f in ipairs { "rules", "board", "sequence", "player", "match" } do
    acc = acc .. (sys.read_file(sys.data_dir() .. "/puyo/" .. f .. ".lua") or f)
  end
  Content._core = Content.hash_string(acc)
  return Content._core
end

return Content
