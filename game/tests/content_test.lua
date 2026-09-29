-- No-code content test (runs inside the engine: buyo-buyo --headless -- --test).
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Builds a content pack the way a non-programmer would - pictures, sounds,
-- an info.txt, folder names with spaces, no Lua at all - and checks that
-- every file-name convention documented in docs/GETTING_STARTED.md loads.
-- The PNGs are painted with the canvas API and the WAVs synthesized here,
-- so the repository needs no binary fixtures.
local Content = require "core.content"
local Skin = require "view.skin"
local Match = require "puyo.match"

local function png(path, w, h, r, g, b)
  local img = gfx.image(w, h)
  img:fill(gfx.shape():rect(0, 0, w, h), r, g, b)
  assert(gfx.save_png(img, path))
end

-- a 16 x 7 sheet of plain circles with `cell`-pixel cells
local function sheet(path, cell)
  local img = gfx.image(16 * cell, 7 * cell)
  for row = 0, 6 do
    for col = 0, 15 do
      local c = cell / 2
      img:fill(gfx.shape():circle(col * cell + c, row * cell + c, c * 0.8), 60 + row * 30, 120, 200)
    end
  end
  assert(gfx.save_png(img, path))
end

local function wav(path, freq, seconds)
  local rate = 22050
  local out = {}
  for i = 0, math.floor(rate * seconds) - 1 do
    out[#out + 1] = string.pack("<i2", math.floor(math.sin(2 * math.pi * freq * i / rate) * 8000))
  end
  local data = table.concat(out)
  local header = "RIFF"
    .. string.pack("<I4", 36 + #data)
    .. "WAVE"
    .. "fmt "
    .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16)
    .. "data"
    .. string.pack("<I4", #data)
  assert(sys.write_file(path, header .. data))
end

return function()
  local passed, failed = 0, 0
  local function check(name, cond, detail)
    if cond then
      passed = passed + 1
    else
      failed = failed + 1
      print("FAIL: " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
  end

  local root = sys.pref_dir() .. "selftest-pack"
  for _, d in ipairs {
    "chars/Test Hero",
    "chars/one_image",
    "stages/Test Stage",
    "skins/Test Skin",
    "music",
    "modes/Test Mode",
  } do
    sys.mkdir(root .. "/" .. d)
  end
  png(root .. "/chars/Test Hero/portrait.png", 64, 64, 255, 90, 70)
  png(root .. "/chars/Test Hero/happy.png", 64, 64, 255, 200, 70)
  wav(root .. "/chars/Test Hero/chain1.wav", 660, 0.2)
  wav(root .. "/chars/Test Hero/chain2.wav", 880, 0.2)
  sys.write_file(
    root .. "/chars/Test Hero/info.txt",
    "# made without code\nname = Tomato Test\ncolor = #ff5a46\ncpu_chain_goal = 2\n"
  )
  png(root .. "/chars/one_image/anything.png", 40, 60, 70, 180, 255)
  png(root .. "/stages/Test Stage/background.png", 64, 36, 30, 20, 60)
  png(root .. "/stages/Test Stage/stars_tile.png", 32, 32, 255, 255, 255)
  wav(root .. "/stages/Test Stage/music.wav", 220, 0.5)
  sys.write_file(root .. "/stages/Test Stage/info.txt", "name: Night Test\nscroll_x = 0.5\n")
  sheet(root .. "/skins/Test Skin/puyos.png", 16)
  wav(root .. "/music/Test Song.wav", 330, 0.5)
  wav(root .. "/music/Canção (remix).wav", 440, 0.2) -- names people really use
  sys.write_file(
    root .. "/modes/Test Mode/info.txt",
    "name = Test Mode\ncolors = 5\npop = 3\ngravity = 80\nbogus = 7\n"
  )

  local saved_skip = Content.skip_user
  Content.skip_user = true
  Content.load_all { root }

  local ch = Content.get("chars", "Test_Hero")
  check("character from files", ch ~= nil, "folder with a space -> id Test_Hero")
  if ch then
    check("info.txt name", ch.name == "Tomato Test", ch.name)
    check("info.txt hex color", ch.color[1] == 255 and ch.color[2] == 90 and ch.color[3] == 70)
    check("portrait.png", ch.portrait == "portrait.png")
    check("mood picture", ch.moods.happy == "happy.png")
    check(
      "chain voices in order",
      ch.voice.chain and ch.voice.chain[1] == "chain1.wav" and ch.voice.chain[2] == "chain2.wav"
    )
    check("cpu personality", ch.cpu.chain_goal == 2)
    check("voice decodes", audio.load(Content.path(ch, "chain1.wav")) ~= nil)
  end
  local one = Content.get("chars", "one_image")
  check("single picture = portrait", one and one.portrait == "anything.png")
  check("name from folder", one and one.name == "One Image", one and one.name)

  local st = Content.get("stages", "Test_Stage")
  check("stage from files", st ~= nil)
  if st then
    check("stage info.txt (key: value)", st.name == "Night Test", st.name)
    check("background fits", st.layers[1].image == "background.png" and st.layers[1].fit == true)
    check(
      "tile layer scrolls",
      st.layers[2] and st.layers[2].tile == true and st.layers[2].scroll_x == 0.5
    )
    local song = Content.get("music", st.music or "")
    check(
      "stage music registered",
      song ~= nil and song.file == "music.wav" and song.hidden == true
    )
  end

  local skdef = Content.get("skins", "Test_Skin")
  check("skin from puyos.png", skdef ~= nil)
  if skdef then
    local ok, sk = pcall(Skin.build, skdef)
    check("skin builds", ok, sk)
    check("cell size detected", ok and sk.cell == 16, ok and sk.cell)
    check("pixel art stays crisp", skdef.filter == "nearest", skdef.filter)
  end

  local song = Content.get("music", "Test_Song")
  check("loose song file", song ~= nil and song.file == "Test Song.wav")
  local remix = Content.get("music", "Can_o_remix_")
  local rp = remix and Content.path(remix, remix.file)
  check(
    "accents and brackets in file names",
    rp ~= nil and audio.load(rp) ~= nil,
    remix and remix.file
  )

  local mode = Content.get("modes", "Test_Mode")
  check("mode from info.txt", mode ~= nil)
  if mode then
    check("unknown keys ignored", mode.rules.bogus == nil)
    local m = Match.new { seed = 1, mode = mode }
    check("mode rules reach the match", m.R.colors == 5 and m.R.pop == 3 and m.R.gravity == 80)
  end

  local mine = 0
  for _, e in ipairs(Content.errors) do
    if e.id:find("Test", 1, true) or e.id == "one_image" or e.id == "Can_o_remix_" then
      mine = mine + 1
      print("FAIL: content error: " .. e.kind .. "/" .. e.id .. ": " .. e.msg)
    end
  end
  check("no content errors", mine == 0)

  -- back to the normal content for the tests that follow
  Content.skip_user = saved_skip
  Content.load_all(Content.extra_roots)
  Skin.clear_cache()

  print(string.format("no-code content test: %d passed, %d failed", passed, failed))
  return failed == 0
end
