-- Scene smoke test (runs inside the engine: buyo-buyo --headless -- --test).
-- SPDX-License-Identifier: GPL-2.0-or-later
--
-- Creates every scene and drives it for a few frames while feeding it the
-- kind of events only a human produces: key presses, typed text, backspace,
-- window focus changes. Headless matches never reach these code paths, so
-- this is what catches crashes like a scene field shadowing a callback.
local Scene = require "core.scene"
local Controls = require "core.controls"

local function drive(make, check)
  local scene = make()
  Scene.go(scene, true)
  for f = 1, 40 do
    Controls.update()
    Scene.update()
    gfx.clear(0, 0, 0)
    Scene.draw()
    if f == 5 then
      Scene.key("A", true, false)
      Scene.key("A", false, false)
    elseif f == 6 then
      Scene.text "3R5XC-8Q"
    elseif f == 7 then
      Scene.key("Backspace", true, false)
      Scene.key("Backspace", false, false)
    elseif f == 8 then
      Scene.focus(false)
      Scene.focus(true)
    elseif f == 9 then
      Scene.key("Down", true, false)
      Scene.key("Down", false, false)
    end
  end
  if check then check(scene) end
end

return function()
  local Versus = require "scenes.versus"
  local scenes = {
    { "title", function() return require("scenes.title").new() end },
    { "select (vs cpu)", function() return require("scenes.select").new { mode = "cpu" } end },
    { "select (2p)", function() return require("scenes.select").new { mode = "2p" } end },
    { "select (watch)", function() return require("scenes.select").new { mode = "watch" } end },
    { "settings", function() return require("scenes.settings").new() end },
    { "content browser", function() return require("scenes.browser").new() end },
    {
      "online lobby",
      function() return require("scenes.online").new { no_stun = true, port = 0 } end,
      function(s)
        -- typed "3R5XC-8Q" then one backspace into the friend's-code field
        assert(
          s.code == "3R5XC-8",
          "typing did not reach the code field (got '" .. tostring(s.code) .. "')"
        )
      end,
    },
    { "versus (demo)", function() return Versus.new(Versus.demo_config()) end },
  }
  local failed = 0
  for _, s in ipairs(scenes) do
    local ok, err = pcall(drive, s[2], s[3])
    if not ok then
      failed = failed + 1
      print(string.format("FAIL: scene %s: %s", s[1], tostring(err)))
    end
  end
  -- leave a clean state (closes the lobby's socket, stops text input)
  pcall(Scene.go, require("scenes.title").new(), true)
  print(string.format("scene smoke test: %d passed, %d failed", #scenes - failed, failed))
  return failed == 0
end
