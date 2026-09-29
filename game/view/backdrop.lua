-- The animated background used behind menus: simply a content stage
-- (settings.menu_stage, falling back to "default").
-- SPDX-License-Identifier: GPL-2.0-or-later
local Content = require "core.content"
local Stage = require "view.stage"

local Backdrop = {}
local current

function Backdrop.reset() current = nil end

function Backdrop.get(id)
  if not current or (id and current.def and current.def.id ~= id) then
    current = Stage.new(Content.pick("stages", id or "default"))
  end
  return current
end

function Backdrop.update() Backdrop.get():update() end

function Backdrop.draw(dim)
  Backdrop.get():draw()
  if dim and dim > 0 then
    gfx.color(8, 4, 24, 255 * dim)
    gfx.rect(0, 0, 1280, 720)
  end
end

return Backdrop
