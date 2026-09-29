-- Blu: a second example character with a different look, voice and CPU style.
-- Full reference: docs/CHARACTERS.md
return {
  name = "Professor Blu",
  author = "Buyo Buyo",
  description = "A patient builder: the CPU waits for bigger chains.",
  order = 2,
  color = { 120, 175, 255 },
  stage = "checkers",
  music = "battle",
  cpu = { chain_goal = 1, speed = 0.9, noise = 0.6 },

  paint = function(img, w, h, mood)
    local cx, cy, r = w * 0.5, h * 0.60, w * 0.35
    local body = gfx.shape():ellipse(cx, cy, r, r * 0.88)
    img:fill(body, 18, 34, 90, 255, { soft = 1.5 })
    img:fill(body, 52, 100, 220, 255, { inset = 5 })
    img:fill(body, 110, 165, 255, 255, { inset = 12, soft = 22, dx = -8, dy = -10 })
    img:fill(
      gfx.shape():ellipse(cx - r * 0.40, cy - r * 0.52, r * 0.26, r * 0.12, -0.6),
      255,
      255,
      255,
      200,
      { soft = 3 }
    )

    -- mortarboard hat
    local hy = cy - r * 0.86
    img:fill(gfx.shape():poly { cx - 70, hy, cx, hy - 26, cx + 70, hy, cx, hy + 26 }, 30, 30, 50)
    img:fill(gfx.shape():rect(cx - 30, hy, 60, 22, 4), 30, 30, 50)
    img:fill(gfx.shape():capsule(cx + 40, hy + 2, cx + 52, hy + 34, 3), 255, 200, 60)

    -- eyes behind round glasses
    local ink = { 16, 20, 50 }
    for side = -1, 1, 2 do
      local ex, ey = cx + side * r * 0.36, cy - r * 0.08
      if mood == "happy" or mood == "win" then
        img:fill(
          gfx
            .shape()
            :capsule(ex - 12, ey + 4, ex, ey - 7, 4)
            :capsule(ex, ey - 7, ex + 12, ey + 4, 4),
          ink[1],
          ink[2],
          ink[3]
        )
      elseif mood == "lose" then
        img:fill(
          gfx
            .shape()
            :capsule(ex - 10, ey - 10, ex + 10, ey + 10, 4)
            :capsule(ex - 10, ey + 10, ex + 10, ey - 10, 4),
          ink[1],
          ink[2],
          ink[3]
        )
      elseif mood == "hurt" then
        img:fill(gfx.shape():capsule(ex - 12, ey, ex + 12, ey, 4), ink[1], ink[2], ink[3])
      else
        img:fill(gfx.shape():circle(ex, ey, 9), ink[1], ink[2], ink[3])
        img:fill(gfx.shape():circle(ex - 3, ey - 3, 3), 255, 255, 255)
      end
      -- glasses: a ring (circle minus a smaller circle)
      img:fill(gfx.shape():circle(ex, ey, 27):circle(ex, ey, 21, "sub"), 230, 230, 240)
    end
    img:fill(gfx.shape():capsule(cx - 12, cy - r * 0.10, cx + 12, cy - r * 0.10, 3), 230, 230, 240) -- bridge

    -- mustache + mouth
    local my = cy + r * 0.30
    img:fill(
      gfx.shape():ellipse(cx - 18, my, 20, 9, 0.25):ellipse(cx + 18, my, 20, 9, -0.25),
      90,
      60,
      40
    )
    if mood == "worried" or mood == "hurt" or mood == "lose" then
      img:fill(gfx.shape():ellipse(cx, my + 22, 9, 7), ink[1], ink[2], ink[3])
    elseif mood == "happy" or mood == "win" then
      img:fill(
        gfx.shape():ellipse(cx, my + 18, 16, 11):rect(cx - 20, my - 4, 40, 22, 0, "sub"),
        ink[1],
        ink[2],
        ink[3]
      )
    end
  end,

  voice = {
    chain = function(n)
      local f = 330 * 2 ^ (math.min(n, 12) * 3 / 12)
      synth { wave = "triangle", freq = f, dur = 0.08, vol = 0.35 }
      synth { wave = "triangle", freq = f * 1.25, dur = 0.08, vol = 0.35, delay = 0.07 }
      synth { wave = "triangle", freq = f * 1.5, dur = 0.14, vol = 0.35, delay = 0.14 }
    end,
    damage = function() synth { wave = "saw", freq = 300, to = 120, dur = 0.25, vol = 0.12 } end,
  },
}
