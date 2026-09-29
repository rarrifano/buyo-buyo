-- Buyo Buyo - entry point.
-- SPDX-License-Identifier: GPL-2.0-or-later
-- The C host calls the callbacks of the table returned here.
--
-- Command line (after `--`), see docs/CLI.md:
--   --mods DIR                 extra content folder (repeatable)
--   --mode cpu|2p|watch        start a match directly (skips menus)
--   --game-mode ID             content mode for --mode (default: tsu)
--   --char1 ID --char2 ID --stage ID --level N --level2 N --first-to N --seed N
--   --host | --connect CODE    online: wait for / connect to a friend
--   --net-port N --net-bot LEVEL --net-sim LAG,JITTER,LOSS --no-stun
--   --export-skin ID FILE      write a skin's sheet as PNG
--   --check-content            validate all content and quit (exit code 1 on errors)
--   --test                     run the self-tests and quit
--   --shots F1,F2 --shot-prefix P --turbo N --skip-draw --quit-at-end   (testing)

-- Content runs sandboxed; make sure it can never reach the real string
-- library through getmetatable("").
getmetatable("").__metatable = false

local Scene = require "core.scene"
local Controls = require "core.controls"
local Settings = require "core.settings"
local Sound = require "core.sound"
local Content = require "core.content"
local Sprites = require "view.sprites"
local Skin = require "view.skin"
local UI = require "view.ui"

local App = {}
local opts = { shots = {}, mods = {} }
local frame = 0
local shot_due = nil

local function parse_args()
  local a = sys.args()
  local i = 1
  local function val()
    i = i + 1
    return a[i]
  end
  while i <= #a do
    local k = a[i]
    if k == "--mods" then
      opts.mods[#opts.mods + 1] = val()
    elseif k == "--mode" then
      opts.mode = val()
    elseif k == "--game-mode" then
      opts.game_mode = val()
    elseif k == "--demo" then
      opts.mode, opts.demo = "watch", true
    elseif k == "--char1" then
      opts.char1 = val()
    elseif k == "--char2" then
      opts.char2 = val()
    elseif k == "--stage" then
      opts.stage = val()
    elseif k == "--level" then
      opts.level = tonumber(val())
    elseif k == "--level2" then
      opts.level2 = tonumber(val())
    elseif k == "--first-to" then
      opts.first_to = tonumber(val())
    elseif k == "--seed" then
      opts.seed = tonumber(val())
    elseif k == "--host" then
      opts.host = true
    elseif k == "--connect" then
      opts.connect = val()
    elseif k == "--net-port" then
      opts.net_port = tonumber(val())
    elseif k == "--net-bot" then
      opts.net_bot = tonumber(val())
    elseif k == "--net-sim" then
      local lag, jit, loss = (val() or ""):match "^(%d+),(%d+),(%d+)$"
      opts.net_sim = lag and { lag = tonumber(lag), jitter = tonumber(jit), loss = tonumber(loss) }
    elseif k == "--no-stun" then
      opts.no_stun = true
    elseif k == "--no-user-mods" then
      opts.no_user_mods = true
    elseif k == "--export-skin" then
      opts.export_skin, opts.export_file = val(), val()
    elseif k == "--check-content" then
      opts.check = true
    elseif k == "--test" then
      opts.test = true
    elseif k == "--shots" then
      for n in (val() or ""):gmatch "%d+" do
        opts.shots[tonumber(n)] = true
      end
    elseif k == "--shot-prefix" then
      opts.shot_prefix = val()
    elseif k == "--turbo" then
      opts.turbo = tonumber(val())
    elseif k == "--skip-draw" then
      opts.skip_draw = true
    elseif k == "--quit-at-end" then
      opts.quit_at_end = true
    end
    i = i + 1
  end
end

-- load every content item for real and smoke-test every mode
local function check_content()
  local Stage = require "view.stage"
  local Char = require "view.char"
  local Match = require "puyo.match"
  local AI = require "puyo.ai"
  for _, def in ipairs(Content.list "skins") do
    local ok, err = pcall(Skin.build, def)
    if not ok then Content.report("skins", def.id, tostring(err)) end
  end
  for _, def in ipairs(Content.list "stages") do
    local st = Stage.new(def)
    for _ = 1, 3 do
      st:update()
    end
    st:draw()
  end
  for _, def in ipairs(Content.list "chars") do
    for _, mood in ipairs(Char.MOODS) do
      Char.texture(def, mood)
    end
    for event, v in pairs(type(def.voice) == "table" and def.voice or {}) do
      local files = type(v) == "string" and { v } or (type(v) == "table" and v or {})
      for _, f in ipairs(files) do
        -- decode for real: a corrupt file must fail here, not in a match
        local p, err = Content.path(def, f)
        local ok
        if p then ok, err = audio.load(p) end
        if not ok then Content.report("chars", def.id, "voice." .. event .. ": " .. tostring(err)) end
      end
    end
  end
  for _, def in ipairs(Content.list "music") do
    if def.file then
      local p, err = Content.path(def, def.file)
      local ok
      if p then ok, err = audio.load(p) end
      if not ok then Content.report("music", def.id, tostring(err)) end
    end
  end
  for _, def in ipairs(Content.list "modes") do
    local m = Match.new {
      seed = 1,
      mode = def,
      rules = { first_to = 1 },
      on_hook_error = function(_, msg) Content.report("modes", def.id, msg) end,
    }
    local bots = { AI.new(4, 1), AI.new(4, 2) }
    for _ = 1, 3600 do
      if m.state == "done" then break end
      m:step(bots[1]:update(m.players[1], m), bots[2]:update(m.players[2], m))
    end
    if def.hud then Content.call(def, "hud", m, Content.sandbox_gfx(), 640, 600) end
  end
  local n = Content.count()
  print(
    string.format(
      "content: %d chars, %d stages, %d skins, %d modes, %d songs, %d errors",
      n.chars,
      n.stages,
      n.skins,
      n.modes,
      n.music,
      #Content.errors
    )
  )
  for _, e in ipairs(Content.errors) do
    print(string.format("  %s/%s: %s", e.kind, e.id, e.msg))
  end
  return #Content.errors == 0
end

local function direct_match()
  local Versus = require "scenes.versus"
  local chars = Content.list "chars"
  local function pick(id, n)
    if Content.get("chars", id) then return id end
    local d = chars[n] or chars[1]
    return d and d.id
  end
  local cpu1 = opts.mode == "watch"
  local cpu2 = opts.mode ~= "2p"
  local c2 = pick(opts.char2, 2)
  local c2def = Content.get("chars", c2)
  return Versus.new {
    kind = opts.mode,
    demo = opts.demo,
    quit_at_end = opts.quit_at_end,
    seed = opts.seed or os.time(),
    mode_id = opts.game_mode or Settings.data.mode or "tsu",
    first_to = opts.first_to or (opts.demo and 1) or Settings.data.first_to,
    stage_id = opts.stage or (c2def and c2def.stage) or "default",
    music_id = "auto",
    colors = Settings.data.colors,
    players = {
      {
        char = pick(opts.char1, 1),
        cpu = cpu1,
        level = opts.level or 3,
        hard_drop = Settings.data.hard_drop,
      },
      {
        char = c2,
        cpu = cpu2,
        level = opts.level2 or opts.level or 3,
        hard_drop = Settings.data.hard_drop,
      },
    },
  }
end

function App.load()
  parse_args()
  -- no argument = time + ASLR address: two processes started in the same
  -- second must not share random numbers (netplay nonces!)
  if opts.seed then
    math.randomseed(opts.seed)
  else
    math.randomseed()
  end
  if opts.test then
    -- pure logic first; the scene smoke test below needs the whole engine
    opts.test_ok = require "tests.rules_test"()
    opts.test_ok = require "tests.netplay_test"() and opts.test_ok
  end
  if not sys.headless() then Settings.load() end -- tests always use defaults
  if opts.net_port then Settings.data.net_port = opts.net_port end
  if opts.first_to then Settings.data.first_to = opts.first_to end
  Settings.apply()
  Content.extra_roots = opts.mods
  Content.skip_user = opts.no_user_mods -- hermetic tests: built-in + --mods only
  Content.load_all(opts.mods)
  Content.ensure_user_dir()
  Sprites.build()
  UI.skin = Skin.get(Settings.data.skin)
  Controls.init()

  if opts.test then
    local ok = require "tests.scenes_test"() and opts.test_ok
    os.exit(ok and 0 or 1, true)
  end

  if opts.export_skin then
    local def = Content.get("skins", opts.export_skin)
    if not def then
      print("no such skin: " .. tostring(opts.export_skin))
      os.exit(1, true)
    end
    local sheet = Skin.sheet(def)
    local file = opts.export_file or ("skin-" .. def.id .. ".png")
    local ok, err = gfx.save_png(sheet, file)
    print(ok and ("wrote " .. file) or err)
    os.exit(ok and 0 or 1, true)
  end
  if opts.check then os.exit(check_content() and 0 or 1, true) end

  if opts.host or opts.connect then
    local Online = require "scenes.online"
    Scene.go(Online.new {
      connect = opts.connect,
      bot = opts.net_bot,
      sim = opts.net_sim,
      no_stun = opts.no_stun,
      quit_at_end = opts.quit_at_end,
      port = opts.net_port,
    })
  elseif opts.mode then
    Scene.go(direct_match())
  else
    Scene.go(require("scenes.title").new())
  end
end

function App.update(_)
  for _ = 1, opts.turbo or 1 do
    frame = frame + 1
    if opts.shots[frame] then shot_due = frame end
    Controls.update()
    Sound.tick()
    Scene.update()
  end
end

function App.draw()
  if opts.skip_draw and not shot_due then return end
  gfx.clear(0, 0, 0)
  Scene.draw()
  if shot_due then
    gfx.screenshot((opts.shot_prefix or "shot_") .. shot_due .. ".bmp")
    shot_due = nil
  end
end

function App.key(name, down, rep) Scene.key(name, down, rep) end
function App.text(str) Scene.text(str) end
function App.focus(on) Scene.focus(on) end

function App.quit()
  if sys.headless() then return end
  Settings.data.fullscreen = sys.fullscreen()
  Settings.save()
end

return App
