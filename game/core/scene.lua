-- Scene stack with fade-to-black transitions.
-- SPDX-License-Identifier: GPL-2.0-or-later
-- A scene may implement: enter(), leave(), update(), draw(), key(name, down, rep), focus(bool)
local Scene = { cur = nil, nxt = nil, fade = 0, dir = 0 }

local FADE_STEP = 1 / 10

function Scene.go(s, instant)
  if not Scene.cur or instant then
    if Scene.cur and Scene.cur.leave then Scene.cur:leave() end
    Scene.cur = s
    if s.enter then s:enter() end
    return
  end
  Scene.nxt = s
  Scene.dir = 1
end

function Scene.update()
  if Scene.dir == 1 then
    Scene.fade = Scene.fade + FADE_STEP
    if Scene.fade >= 1 then
      Scene.fade = 1
      if Scene.cur.leave then Scene.cur:leave() end
      Scene.cur = Scene.nxt
      Scene.nxt = nil
      if Scene.cur.enter then Scene.cur:enter() end
      Scene.dir = -1
    end
    return -- freeze the old scene while fading out
  elseif Scene.dir == -1 then
    Scene.fade = Scene.fade - FADE_STEP
    if Scene.fade <= 0 then
      Scene.fade = 0
      Scene.dir = 0
    end
  end
  if Scene.cur and Scene.cur.update then Scene.cur:update() end
end

function Scene.busy() return Scene.dir ~= 0 end

function Scene.draw()
  if Scene.cur and Scene.cur.draw then Scene.cur:draw() end
  if Scene.fade > 0 then
    gfx.color(8, 4, 20, 255 * Scene.fade)
    gfx.rect(0, 0, 1280, 720)
  end
end

function Scene.key(name, down, rep)
  if Scene.cur and Scene.cur.key and Scene.dir == 0 then Scene.cur:key(name, down, rep) end
end

function Scene.text(str)
  if Scene.cur and Scene.cur.text and Scene.dir == 0 then Scene.cur:text(str) end
end

function Scene.focus(on)
  if Scene.cur and Scene.cur.focus then Scene.cur:focus(on) end
end

return Scene
