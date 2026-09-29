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
Content.FILE = {
  chars = "char.lua",
  stages = "stage.lua",
  skins = "skin.lua",
  modes = "mode.lua",
  music = "song.lua",
}
Content.API_VERSION = 1

Content.items = {} -- kind -> id -> def
Content.lists = {} -- kind -> sorted array of defs
Content.errors = {} -- { kind=, id=, msg= }
Content.roots = {}

local SAFE_BASE = {
  "assert",
  "error",
  "ipairs",
  "next",
  "pairs",
  "pcall",
  "select",
  "tonumber",
  "tostring",
  "type",
  "xpcall",
  "rawequal",
  "rawlen",
  "setmetatable",
  "getmetatable",
}
local SAFE_GFX = {
  "color",
  "rect",
  "rect_line",
  "line",
  "circle",
  "draw",
  "drawq",
  "stretch",
  "text",
  "text_width",
  "blend",
  "size",
  "image",
  "shape",
}

Content.PALETTE = {
  { 255, 76, 92 },
  { 70, 214, 100 },
  { 70, 130, 255 },
  { 255, 210, 50 },
  { 186, 96, 255 },
  { 205, 212, 232 },
}

------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------

-- FNV-1a 32 of a string, as 8 hex digits
function Content.hash_string(s)
  local h = 2166136261
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff
  end
  return string.format("%08x", h)
end

local function shallow_copy(t)
  local r = {}
  for k, v in pairs(t) do
    r[k] = v
  end
  return r
end

-- resolve a file name relative to an item folder; refuses to escape it
function Content.path(def, name)
  if type(name) ~= "string" or name == "" then return nil, "file name expected" end
  if
    name:find("..", 1, true)
    or name:match "^[/\\]"
    or name:match "^%a:"
    -- anything else a file can be called on every OS is fine, e.g. "My Song
    -- (remix).ogg" or accented names: no control chars, \ : * ? " < > |
    or name:find '[%c\\:*?"<>|]'
  then
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
    Content.report(
      def.kind,
      def.id,
      string.format("%s() failed and was disabled: %s", name, tostring(a))
    )
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
    for _, k in ipairs(SAFE_GFX) do
      safe_gfx[k] = gfx[k]
    end
  end
  return readonly(safe_gfx)
end

local asset_cache = setmetatable({}, { __mode = "v" })

local function make_env(kind, def)
  local env = {}
  for _, k in ipairs(SAFE_BASE) do
    env[k] = _G[k]
  end
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
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
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
    env.synth = function(t)
      if type(t) == "table" then audio.play(t) end
    end
  end
  return env
end

------------------------------------------------------------------------
-- validation per kind
------------------------------------------------------------------------

local function color3(c, default)
  if
    type(c) == "table"
    and type(c[1]) == "number"
    and type(c[2]) == "number"
    and type(c[3]) == "number"
  then
    return { c[1], c[2], c[3] }
  end
  return default
end

local VALIDATE = {}

function VALIDATE.chars(d)
  d.color = color3(d.color, { 255, 255, 255 })
  if d.portrait ~= nil and type(d.portrait) ~= "string" then
    return "portrait must be a file name"
  end
  if d.paint ~= nil and type(d.paint) ~= "function" then return "paint must be a function" end
  if d.moods ~= nil and type(d.moods) ~= "table" then
    return "moods must be a table of file names"
  end
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
    return 'a skin needs either sheet = "file.png" or a paint(img, cell, api) function'
  end
  if d.auto_cell then return nil end -- measured from the sheet width (view/skin.lua)
  d.cell = math.tointeger(d.cell) or 64
  if d.cell < 8 or d.cell > 256 then return "cell must be between 8 and 256" end
end

function VALIDATE.modes(d)
  if d.rules ~= nil and type(d.rules) ~= "table" then return "rules must be a table" end
  for k, v in pairs(d) do
    if
      type(v) == "function"
      and not ({
        init = 1,
        round_start = 1,
        frame = 1,
        link = 1,
        chain_end = 1,
        pair = 1,
        garbage = 1,
        winner = 1,
        hud = 1,
      })[k]
    then
      return "unknown hook '" .. k .. "' (see docs/MODES.md)"
    end
  end
end

function VALIDATE.music(d)
  if type(d.file) ~= "string" and type(d.channels) ~= "table" then
    return 'a song needs file = "song.ogg" or chiptune channels = { ... }'
  end
end

------------------------------------------------------------------------
-- loading
------------------------------------------------------------------------

-- validate a finished definition and put it in the registry
local function register(kind, id, def)
  def.name = type(def.name) == "string" and def.name or id
  def.author = type(def.author) == "string" and def.author or "unknown"
  local verr = VALIDATE[kind](def)
  if verr then return Content.report(kind, id, verr) end
  local prev = Content.items[kind][id]
  if prev then def.overrides = prev.root end
  Content.items[kind][id] = def
end

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
  if type(result) ~= "table" then
    return Content.report(kind, id, "the file must return a table")
  end
  for k, v in pairs(result) do
    if def[k] == nil then def[k] = v end
  end
  def.hash = Content.hash_string(src)
  register(kind, id, def)
end

------------------------------------------------------------------------
-- content without code: a folder of images / sounds + an optional info.txt
------------------------------------------------------------------------

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }
local AUDIO_EXT = { ogg = true, wav = true }

local function ext_of(name) return (name:match "%.(%w+)$" or ""):lower() end
local function stem_of(name) return (name:gsub("%.%w+$", "")):lower() end

-- "tomato_king" -> "Tomato King"
local function pretty(id)
  local s = id:gsub("[_%-]+", " ")
  return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end

-- info.txt: one "key = value" (or "key: value") per line; # starts a comment
function Content.parse_info(text)
  local t = {}
  for line in (text .. "\n"):gmatch "([^\n]*)\n" do
    line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:match "^[#;]" and not line:match "^%-%-" then
      local k, v = line:match "^([%w_%.%-]+)%s*[=:]%s*(.-)$"
      if k then t[k:lower()] = (v:gsub('^"(.*)"$', "%1")) end
    end
  end
  return t
end

-- "255, 90, 70" or "#ff5a46"
function Content.parse_color(v)
  if type(v) ~= "string" then return nil end
  local hex = v:match "^#?(%x%x%x%x%x%x)$"
  if hex then
    return { tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16) }
  end
  local r, g, b = v:match "^(%d+)[%s,]+(%d+)[%s,]+(%d+)$"
  if r then return { tonumber(r), tonumber(g), tonumber(b) } end
  return nil
end

-- "12" -> 12, "yes"/"on"/"true" -> true, anything else stays a string
local function info_value(v)
  if v == nil then return nil end
  local l = v:lower()
  if l == "true" or l == "yes" or l == "on" then return true end
  if l == "false" or l == "no" or l == "off" then return false end
  local n = tonumber(v)
  if n then return math.tointeger(n) or n end
  return v
end

local AUTO = {}

-- finder over the folder's files: find("image"|"audio", stem1, stem2, ...)
local function finder(files)
  local by_key, lists = {}, { image = {}, audio = {} }
  for _, f in ipairs(files) do
    local e = ext_of(f)
    local k = IMAGE_EXT[e] and "image" or (AUDIO_EXT[e] and "audio" or nil)
    if k then
      local key = k .. ":" .. stem_of(f)
      by_key[key] = by_key[key] or f
      lists[k][#lists[k] + 1] = f
    end
  end
  local function find(kind, ...)
    for i = 1, select("#", ...) do
      local f = by_key[kind .. ":" .. select(i, ...)]
      if f then return f end
    end
    return nil
  end
  return find, lists
end

function AUTO.chars(def, info, find, lists)
  local moods = {}
  for _, mood in ipairs { "idle", "happy", "worried", "hurt", "win", "lose" } do
    moods[mood] = find("image", mood)
  end
  def.portrait = find("image", "portrait", "character", "char", "idle")
    or (#lists.image == 1 and lists.image[1])
    or nil
  def.moods = moods
  if not def.portrait and next(moods) == nil then
    return "no char.lua here - add a portrait.png (see docs/GETTING_STARTED.md)"
  end
  local voice, chain = {}, {}
  for n = 1, 20 do
    local f = find("audio", "chain" .. n)
    if not f then break end
    chain[#chain + 1] = f
  end
  if #chain == 0 then chain[1] = find("audio", "chain") end
  voice.chain = #chain > 0 and chain or nil
  for _, ev in ipairs { "start", "attack", "damage", "win", "lose" } do
    voice[ev] = find("audio", ev)
  end
  voice.all_clear = find("audio", "all_clear", "allclear")
  def.voice = voice
  def.color = Content.parse_color(info.color)
  def.skin, def.stage, def.music = info.skin, info.stage, info.music
  def.cpu = {
    chain_goal = tonumber(info.cpu_chain_goal or info.chain_goal),
    speed = tonumber(info.cpu_speed),
    noise = tonumber(info.cpu_noise),
  }
end

function AUTO.stages(def, info, find, lists, extras)
  if #lists.image == 0 then
    return "no stage.lua here - add a background.png (see docs/GETTING_STARTED.md)"
  end
  local bg = find("image", "background", "bg", "back")
  if not bg and #lists.image == 1 then bg = lists.image[1] end
  local layers = {}
  if bg then layers[1] = { image = bg, fit = true } end
  for _, f in ipairs(lists.image) do
    if f ~= bg then
      if stem_of(f):find("tile", 1, true) then
        -- repeating pattern that drifts slowly
        layers[#layers + 1] = {
          image = f,
          tile = true,
          scroll_x = tonumber(info.scroll_x) or 0.25,
          scroll_y = tonumber(info.scroll_y) or 0,
          alpha = tonumber(info.tile_alpha) or 255,
        }
      else
        layers[#layers + 1] = { image = f } -- a full-size overlay, drawn at the top-left
      end
    end
  end
  def.layers = layers
  local top = Content.parse_color(info.top_color or info.color)
  local bottom = Content.parse_color(info.bottom_color or info.color)
  if top then def.gradient = { top = top, bottom = bottom or top } end
  -- a song inside the stage folder plays on this stage
  local song = find("audio", "music", "song", "theme") or lists.audio[1]
  if song then
    local sid = "stage_" .. def.id
    extras[#extras + 1] = {
      kind = "music",
      id = sid,
      def = {
        id = sid,
        kind = "music",
        folder = def.folder,
        source = def.folder .. "/" .. song,
        root = def.root,
        file = song,
        hidden = true,
        auto = true,
        hash = "0",
        name = pretty(def.id) .. " theme",
        author = info.author,
      },
    }
    def.music = sid
  else
    def.music = info.music
  end
end

function AUTO.skins(def, info, find, lists)
  local sheet = find("image", "puyos", "sheet", "skin")
    or (#lists.image == 1 and lists.image[1])
    or nil
  if not sheet then return "no skin.lua here - add a puyos.png sheet (see docs/SKINS.md)" end
  def.sheet = sheet
  def.cell = math.tointeger(tonumber(info.cell))
  def.auto_cell = def.cell == nil -- measured from the sheet width when loaded
  def.filter = info.filter
  if info.faces ~= nil then def.faces = info_value(info.faces) end
  local colors = {}
  for i = 1, 6 do
    colors[i] = Content.parse_color(info["color" .. i])
    if not colors[i] then
      colors = nil
      break
    end
  end
  def.colors = colors
end

function AUTO.music(def, info, find, lists, _, single)
  local f = single or find("audio", "song", "music") or lists.audio[1]
  if not f then return "no song.lua here - add an .ogg or .wav file (see docs/MUSIC.md)" end
  def.file = f
  if info.loop ~= nil then def.loop = info_value(info.loop) end
  def.loop_start = tonumber(info.loop_start)
  def.volume = tonumber(info.volume)
end

function AUTO.modes(def, info)
  local rules = {}
  for k, v in pairs(info) do
    local d = Rules.DEFAULTS[k]
    if d ~= nil and type(d) ~= "table" then rules[k] = info_value(v) end
  end
  if next(rules) == nil then
    return "no mode.lua here - add an info.txt with rules, e.g. gravity = 60 (see docs/MODES.md)"
  end
  def.rules = rules
end

local function load_auto(kind, id, folder, root, single)
  local files = {}
  if single then
    files[1] = single
  else
    for _, e in ipairs(sys.list_dir(folder)) do
      if not e.dir then files[#files + 1] = e.name end
    end
    table.sort(files)
  end
  local info_text
  for _, f in ipairs(files) do
    if f:lower() == "info.txt" and not single then info_text = sys.read_file(folder .. "/" .. f) end
  end
  local info = info_text and Content.parse_info(info_text) or {}
  local def = {
    id = id,
    kind = kind,
    folder = folder,
    root = root.label,
    auto = true,
    single = single,
    source = folder .. "/" .. (single or "info.txt"),
  }
  local find, lists = finder(files)
  local extras = {}
  local err = AUTO[kind](def, info, find, lists, extras, single)
  if err then return Content.report(kind, id, err) end
  def.name = info.name or pretty(id)
  def.author = info.author
  def.description = def.description or info.description
  def.order = tonumber(info.order)
  -- fingerprint (modes are compared online): the settings and the file list
  def.hash = Content.hash_string((info_text or "") .. "\n" .. table.concat(files, "\n"))
  register(kind, id, def)
  for _, x in ipairs(extras) do
    register(x.kind, x.id, x.def)
  end
end

function Content.default_roots(extra)
  local roots = { { path = sys.data_dir() .. "/../content", label = "built-in" } }
  local pref = sys.pref_dir()
  if pref and pref ~= "" and not Content.skip_user then
    roots[#roots + 1] = { path = pref .. "mods", label = "user" }
  end
  for _, p in ipairs(extra or {}) do
    roots[#roots + 1] = { path = p, label = "extra" }
  end
  return roots
end

-- make sure the user mods folder exists and explains itself
function Content.ensure_user_dir()
  local pref = sys.pref_dir()
  if not pref or pref == "" or sys.headless() then return nil end
  local dir = pref .. "mods"
  if sys.exists(dir) ~= "dir" then
    sys.mkdir(dir)
    for _, k in ipairs(Content.KINDS) do
      sys.mkdir(dir .. "/" .. k)
    end
    sys.write_file(
      dir .. "/README.txt",
      table.concat({
        "Buyo Buyo user content folder",
        "",
        "Drop content packs here, one folder per item:",
        "  chars/<id>/char.lua    stages/<id>/stage.lua    skins/<id>/skin.lua",
        "  modes/<id>/mode.lua    music/<id>/song.lua",
        "",
        "Items here override built-in items with the same id.",
        "Press F5 in game to reload. The full guide is in docs/ (docs/README.md).",
        "",
      }, "\n")
    )
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
            -- ids come from folder/file names; be forgiving with spaces etc.
            local id, folder, file, single
            local auto = false
            if e.dir then
              id, folder = e.name, dir .. "/" .. e.name
              file = folder .. "/" .. Content.FILE[kind]
              if sys.exists(file) ~= "file" then
                file, auto = nil, true -- no code: build it from the files inside
              end
            elseif kind == "music" and e.name:match "%.lua$" then
              id, folder, file = e.name:gsub("%.lua$", ""), dir, dir .. "/" .. e.name
            elseif kind == "music" and AUDIO_EXT[ext_of(e.name)] then
              id, folder, single = e.name:gsub("%.%w+$", ""), dir, e.name -- a loose song file
            end
            if id then
              id = id:gsub("[^%w_%-]+", "_")
              if file then
                load_item(kind, id, folder, file, root)
              elseif auto or single then
                load_auto(kind, id, folder, root, single)
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
      if def.hidden ~= true then list[#list + 1] = def end
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
    local stub = {
      id = "nobody",
      kind = "chars",
      name = "Nobody",
      author = "engine",
      color = { 230, 230, 240 },
      folder = ".",
      source = "",
      root = "engine",
      hash = "0",
    }
    Content.items.chars.nobody = stub
    Content.lists.chars = { stub }
    Content.report(
      "chars",
      "nobody",
      "no characters found - install some into "
        .. (Content.roots[2] and Content.roots[2].path or "mods")
    )
  end
end

function Content.get(kind, id) return id and Content.items[kind] and Content.items[kind][id] or nil end

function Content.list(kind) return Content.lists[kind] or {} end

-- first item of a kind, preferring `id`
function Content.pick(kind, id) return Content.get(kind, id) or Content.list(kind)[1] end

function Content.count()
  local n = {}
  for _, k in ipairs(Content.KINDS) do
    n[k] = #Content.list(k)
  end
  return n
end

-- Fingerprint of the code that must be identical for two players to play
-- online: the simulation and the netcode. Not the git version string - the
-- same code with a local edit elsewhere ("-dirty") must still connect.
-- main.lua computes it at startup, i.e. from the files that were loaded.
function Content.core_hash()
  if Content._core then return Content._core end
  local acc = sys.base_version or sys.version
  local files = {
    "puyo/rules",
    "puyo/board",
    "puyo/sequence",
    "puyo/player",
    "puyo/match",
    "core/util",
    "net/rollback",
    "net/pack",
  }
  for _, f in ipairs(files) do
    -- CRLF (a Windows git checkout) must not look like different code
    local src = sys.read_file(sys.data_dir() .. "/" .. f .. ".lua") or f
    acc = acc .. src:gsub("\r\n", "\n")
  end
  Content._core = Content.hash_string(acc)
  return Content._core
end

return Content
