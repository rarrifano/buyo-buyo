-- UI drawing helpers: shadowed / outlined text, rounded panels, menus.
-- SPDX-License-Identifier: GPL-2.0-or-later
local Content = require "core.content"

local UI = {}

UI.WHITE = { 255, 255, 255 }
UI.YELLOW = { 255, 220, 90 }
UI.GRAY = { 170, 170, 200 }
UI.DIM = { 120, 118, 160 }
UI.P1 = { 255, 120, 130 }
UI.P2 = { 120, 180, 255 }

function UI.text(s, x, y, scale, align, col, alpha)
  col = col or UI.WHITE
  alpha = alpha or 255
  local o = math.max(1, scale * 0.75)
  gfx.color(10, 6, 30, alpha * 0.7)
  gfx.text(s, x + o, y + o, scale, align)
  gfx.color(col[1], col[2], col[3], alpha)
  gfx.text(s, x, y, scale, align)
end

-- thick outline (8 directions), for big titles and popups
function UI.outline(s, x, y, scale, align, col, ocol, alpha)
  col = col or UI.WHITE
  ocol = ocol or { 20, 10, 40 }
  alpha = alpha or 255
  local o = math.max(1, math.min(scale, 2 + scale * 0.5))
  gfx.color(ocol[1], ocol[2], ocol[3], alpha)
  for dx = -1, 1 do
    for dy = -1, 1 do
      if dx ~= 0 or dy ~= 0 then gfx.text(s, x + dx * o, y + dy * o, scale, align) end
    end
  end
  gfx.color(col[1], col[2], col[3], alpha)
  gfx.text(s, x, y, scale, align)
end

-- rainbow text: every letter a puyo color, gently bobbing.
-- Two passes (all outlines, then all letters) so outlines never cover a
-- neighbouring letter.
function UI.rainbow(s, x, y, scale, t, align, alpha)
  alpha = alpha or 255
  local w = #s * 8 * scale
  if align == "center" then
    x = x - w / 2
  elseif align == "right" then
    x = x - w
  end
  local o = math.max(1, math.min(scale, 2 + scale * 0.5))
  for pass = 1, 2 do
    for k = 1, #s do
      local ch = s:sub(k, k)
      if ch ~= " " then
        local lx = x + (k - 1) * 8 * scale
        local ly = y + math.sin(t * 0.15 + k * 0.7) * scale
        if pass == 1 then
          gfx.color(20, 10, 40, alpha)
          for dx = -1, 1 do
            for dy = -1, 1 do
              if dx ~= 0 or dy ~= 0 then gfx.text(ch, lx + dx * o, ly + dy * o, scale) end
            end
          end
        else
          local col = Content.PALETTE[(k - 1) % 5 + 1]
          gfx.color(col[1], col[2], col[3], alpha)
          gfx.text(ch, lx, ly, scale)
        end
      end
    end
  end
end

-- split text into lines of at most `width` characters, breaking at spaces
function UI.wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch "%S+" do
    while #word > width do
      if #line > 0 then
        lines[#lines + 1] = line
        line = ""
      end
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if #line == 0 then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

-- draw wrapped text; returns the y after the last line
function UI.paragraph(text, x, y, width_chars, scale, align, col, max_lines)
  for k, l in ipairs(UI.wrap(text, width_chars)) do
    if max_lines and k > max_lines then break end
    UI.text(l, x, y, scale, align or "left", col)
    y = y + 10 * scale
  end
  return y
end

-- keep the end of a long string (e.g. a path): "...tail"
function UI.tail(s, n)
  s = tostring(s)
  if #s <= n then return s end
  return "..." .. s:sub(-(n - 3))
end

local panels = {}

UI.BORDER = { 200, 205, 255 }

-- rounded translucent panel with a light border (cached per size + color)
function UI.panel(x, y, w, h, alpha, border)
  w, h = math.floor(w), math.floor(h)
  border = border or UI.BORDER
  local key = w .. "x" .. h .. ":" .. border[1] .. "," .. border[2] .. "," .. border[3]
  local tex = panels[key]
  if not tex then
    local img = gfx.image(w, h)
    local sh = gfx.shape():rect(1.5, 1.5, w - 3, h - 3, math.min(18, h / 2))
    img:fill(sh, border[1], border[2], border[3], 255, { soft = 1.2 })
    img:fill(sh, 0, 0, 0, 255, { inset = 3.5, mode = "erase" })
    img:fill(sh, 18, 14, 46, 228, { inset = 3.5 })
    tex = img:texture()
    panels[key] = tex
  end
  gfx.color(255, 255, 255, alpha or 255)
  gfx.draw(tex, x, y)
end

local frames = {}

-- just the rounded border ring (cached per size)
function UI.frame(x, y, w, h, col, alpha)
  w, h = math.floor(w), math.floor(h)
  local key = w .. "x" .. h
  local tex = frames[key]
  if not tex then
    local img = gfx.image(w, h)
    local r = math.min(18, h / 2)
    local sh = gfx.shape():rect(1.5, 1.5, w - 3, h - 3, r)
    img:fill(sh, 255, 255, 255, 255, { soft = 1.2 })
    img:fill(sh, 0, 0, 0, 255, { inset = 3.5, soft = 1.2, mode = "erase" })
    tex = img:texture()
    frames[key] = tex
  end
  col = col or { 200, 205, 255 }
  gfx.color(col[1], col[2], col[3], alpha or 255)
  gfx.draw(tex, x, y)
end

-- vertical menu. items: list of strings; returns nothing.
function UI.menu(items, sel, cx, y, t, opts)
  opts = opts or {}
  local scale = opts.scale or 3
  local gap = opts.gap or 44
  for k, label in ipairs(items) do
    local yy = y + (k - 1) * gap
    local on = k == sel
    local col = on and UI.YELLOW or (opts.dim and opts.dim[k] and UI.DIM or UI.WHITE)
    local bounce = on and math.sin(t * 0.2) * 2 or 0
    UI.text(label, cx, yy + bounce, scale, "center", col, on and 255 or 210)
    if on and UI.skin then
      local w = #label * 8 * scale
      local s = 8 * scale + 10
      local c = (math.floor(t / 30) % 5) + 1
      UI.skin:puyo(c, cx - w / 2 - s * 0.9, yy + 4 * scale + bounce, s, 0, "open")
      UI.skin:puyo(c, cx + w / 2 + s * 0.9, yy + 4 * scale + bounce, s, 0, "open")
    end
  end
end

return UI
