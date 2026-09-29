-- Virtual controllers: map keyboard profiles and gamepads onto the buttons
-- the game understands. Polled once per frame.
--
-- Buttons: left right up down rot_l rot_r start confirm back
local Controls = {}

local BUTTONS = { "left", "right", "up", "down", "rot_l", "rot_r", "start", "confirm", "back" }
Controls.BUTTONS = BUTTONS

-- keyboard profiles (SDL scancode names)
Controls.KEYS = {
  -- VS CPU: one human, every sensible key works
  solo = {
    left = { "Left", "A" }, right = { "Right", "D" }, up = { "Up", "W" }, down = { "Down", "S" },
    rot_l = { "Z", "J" }, rot_r = { "X", "K" },
  },
  -- 2P, left side of the keyboard
  p1 = {
    left = { "A" }, right = { "D" }, up = { "W" }, down = { "S" },
    rot_l = { "F" }, rot_r = { "G" },
  },
  -- 2P, right side of the keyboard
  p2 = {
    left = { "Left" }, right = { "Right" }, up = { "Up" }, down = { "Down" },
    rot_l = { "," }, rot_r = { "." },
  },
  -- menus (and pause)
  menu = {
    left = { "Left", "A" }, right = { "Right", "D" }, up = { "Up", "W" }, down = { "Down", "S" },
    confirm = { "Return", "Space", "Z", "J", "Keypad Enter" },
    back = { "Escape", "Backspace", "X", "K" },
    start = { "Escape", "Return", "P" },
  },
}

-- SDL game controller buttons (south = a, east = b, west = x, north = y)
Controls.PAD = {
  left = { "dpleft" }, right = { "dpright" }, up = { "dpup" }, down = { "dpdown" },
  rot_l = { "a", "x" }, rot_r = { "b", "y" },
  start = { "start" }, confirm = { "a", "start" }, back = { "b", "back" },
}

local Ctl = {}
Ctl.__index = Ctl

local all = {}

-- profile: key profile name; pads: list of pad slots, "all", or nil
function Controls.new(profile, pads)
  local c = setmetatable({ held = {}, pressed = {}, released = {}, frames = {}, keys = {}, pads = pads }, Ctl)
  for b, names in pairs(Controls.KEYS[profile] or {}) do
    local list = {}
    for _, n in ipairs(names) do
      local sc = input.scancode(n)
      if sc and sc > 0 then list[#list + 1] = sc end
    end
    c.keys[b] = list
  end
  for _, b in ipairs(BUTTONS) do
    c.held[b], c.pressed[b], c.released[b], c.frames[b] = false, false, false, 0
  end
  return c
end

local function pad_down(slot, b)
  if not input.pad_connected(slot) then return false end
  for _, name in ipairs(Controls.PAD[b] or {}) do
    if input.pad(slot, name) then return true end
  end
  if b == "left" then return input.axis(slot, "leftx") < -0.5 end
  if b == "right" then return input.axis(slot, "leftx") > 0.5 end
  if b == "up" then return input.axis(slot, "lefty") < -0.6 end
  if b == "down" then return input.axis(slot, "lefty") > 0.6 end
  return false
end

function Ctl:poll()
  for _, b in ipairs(BUTTONS) do
    local down = false
    local ks = self.keys[b]
    if ks then
      for i = 1, #ks do
        if input.key(ks[i]) then down = true break end
      end
    end
    if not down and self.pads then
      if self.pads == "all" then
        for slot = 1, input.MAX_PADS do
          if pad_down(slot, b) then down = true break end
        end
      else
        for _, slot in ipairs(self.pads) do
          if pad_down(slot, b) then down = true break end
        end
      end
    end
    self.pressed[b] = down and not self.held[b]
    self.released[b] = self.held[b] and not down
    self.held[b] = down
    self.frames[b] = down and self.frames[b] + 1 or 0
  end
end

-- press + auto-repeat, for menus
function Ctl:rep(b)
  local f = self.frames[b]
  return f == 1 or (f > 22 and (f - 22) % 5 == 0)
end

-- make a controller that is polled automatically every frame
function Controls.register(profile, pads)
  local c = Controls.new(profile, pads)
  all[#all + 1] = c
  c:poll()
  return c
end

function Controls.unregister(c)
  for i = #all, 1, -1 do
    if all[i] == c then table.remove(all, i) end
  end
end

function Controls.init()
  Controls.menu = Controls.register("menu", "all")
end

function Controls.update()
  for _, c in ipairs(all) do c:poll() end
end

-- human readable key help
Controls.HELP = {
  { "VS CPU", {
    "Move        \001 \002  or  A D",
    "Soft drop   \004  or  S",
    "Hard drop   \003  or  W  (if enabled)",
    "Rotate      Z X  or  J K",
  } },
  { "2P - Player 1", { "Move A D   Drop S   Hard drop W", "Rotate F G" } },
  { "2P - Player 2", { "Move \001 \002   Drop \004   Hard drop \003", "Rotate , ." } },
  { "Gamepad", { "D-pad/stick move, A/X rotate left, B/Y rotate right", "Start pauses. Pad 1 = P1, pad 2 = P2" } },
  { "General", { "Esc/Enter pause    F11 or Alt+Enter fullscreen" } },
}

return Controls
