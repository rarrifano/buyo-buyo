-- A mode with hooks: every 20 seconds it rains nuisance on BOTH players,
-- and all-clears are worth double. Shows the hook API and HUD drawing.
--
-- Hooks run inside the simulation, which must be 100% deterministic (both
-- netplay peers replay it): only use `m`, `p` and their data, keep your
-- state in m.data, and use m.rng:int(a, b) instead of math.random.
-- Full reference: docs/MODES.md
local EVERY = 20 * 60 -- frames between showers
local AMOUNT = 6 -- one row

return {
  name = "Nuisance Rain",
  author = "Buyo Buyo",
  description = "Every 20 seconds both players get a row of nuisance. All clears count double.",
  order = 3,
  rules = { first_to = 2 },

  init = function(m) m.data.showers = 0 end,

  round_start = function(m) m.data.next = EVERY end,

  -- called once per frame while a round is being played
  frame = function(m)
    if m.frames >= m.data.next then
      m.data.next = m.data.next + EVERY
      m.data.showers = m.data.showers + 1
      for _, p in ipairs(m.players) do
        p:add_garbage(AMOUNT)
      end
      m:emit(nil, "announce", { text = "RAIN!", color = { 150, 200, 255 } })
    end
  end,

  -- called for every chain link; return the (possibly modified) link
  link = function(m, _, link)
    if link.all_clear then link.garbage = link.garbage + m.R.all_clear_garbage end
    return link
  end,

  -- draws on top of the match (visual only, never affects the game)
  hud = function(m, gfx, x, y)
    local left = math.max(0, (m.data.next or EVERY) - m.frames)
    gfx.color(150, 200, 255)
    gfx.text(string.format("RAIN IN %2d", left // 60), x, y, 2, "center")
  end,
}
