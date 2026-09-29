-- The default stage: a gradient with drifting translucent bubbles, all scripted.
-- Full reference: docs/STAGES.md
return {
  name = "Bubble Night",
  author = "Buyo Buyo",
  order = 1,
  music = "battle", -- song id from content/music
  gradient = { top = { 44, 30, 96 }, bottom = { 16, 12, 44 } },

  -- `state` is a table you own; init/update/draw receive it every time.
  -- Stages are purely visual, so math.random is fine here.
  init = function(state)
    state.bubbles = {}
    for k = 1, 26 do
      state.bubbles[k] = {
        x = math.random() * 1280,
        y = math.random() * 760,
        r = 20 + math.random() * 55,
        speed = 0.15 + math.random() * 0.45,
        color = PALETTE[(k - 1) % 5 + 1],
        wobble = math.random() * 6.28,
      }
    end
  end,

  update = function(state, _)
    for _, b in ipairs(state.bubbles) do
      b.y = b.y - b.speed
      b.wobble = b.wobble + 0.01
      if b.y < -b.r then
        b.y = 720 + b.r
        b.x = math.random() * 1280
      end
    end
  end,

  draw = function(state, _)
    for _, b in ipairs(state.bubbles) do
      gfx.color(b.color[1], b.color[2], b.color[3], 34)
      gfx.circle(b.x + math.sin(b.wobble) * 20, b.y, b.r)
    end
  end,
}
