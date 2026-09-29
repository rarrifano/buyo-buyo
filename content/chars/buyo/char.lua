-- Buyo, the default character. Everything here is optional except `name`.
-- Copy this folder to <your mods folder>/chars/<new_id>/ to make your own.
-- Full reference: docs/CHARACTERS.md
return {
  name = "Buyo",
  author = "Buyo Buyo",
  description = "The default mascot: a cheerful red blob with a big yellow bow.",
  order = 1,                  -- position in the select screen (lower = first)
  color = { 255, 110, 125 },  -- accent color for names / UI

  skin = "classic",           -- preferred puyo skin (players can override)
  stage = "default",          -- home stage (used when the stage is "auto")
  music = "battle",           -- theme song id (content/music)

  -- How the CPU plays this character (on top of the chosen difficulty):
  --   chain_goal: + fires bigger chains, - fires earlier
  --   speed:      > 1 moves faster, < 1 slower
  --   noise:      > 1 makes more random choices
  cpu = { chain_goal = 0, speed = 1.0, noise = 1.0 },

  -- The portrait. Use `portrait = "portrait.png"` (and optionally
  -- `moods = { happy = "happy.png", ... }`) for image files, or paint it with
  -- code like here. paint() runs once per mood; the result is cached.
  -- Moods: idle, happy, worried, hurt, win, lose
  paint = function(img, w, h, mood)
    local cx, cy, r = w * 0.5, h * 0.60, w * 0.34
    -- body: outline, shade, light core, shine
    local body = gfx.shape():ellipse(cx, cy, r, r * 0.9)
    img:fill(body, 90, 20, 36, 255, { soft = 1.5 })
    img:fill(body, 205, 58, 78, 255, { inset = 5 })
    img:fill(body, 255, 118, 132, 255, { inset = 12, soft = 22, dx = -8, dy = -10 })
    img:fill(gfx.shape():ellipse(cx - r * 0.42, cy - r * 0.50, r * 0.28, r * 0.13, -0.6), 255, 255, 255, 210, { soft = 3 })

    -- the bow
    local bx, by = cx + r * 0.42, cy - r * 0.78
    local bow = gfx.shape()
      :poly { bx, by, bx - 40, by - 26, bx - 40, by + 26 }
      :poly { bx, by, bx + 40, by - 26, bx + 40, by + 26 }
      :circle(bx, by, 11)
    img:fill(bow, 110, 70, 10, 255, { inset = -3, soft = 1.5 })
    img:fill(bow, 255, 214, 70, 255)

    -- eyes
    local ink = { 40, 16, 40 }
    for side = -1, 1, 2 do
      local ex, ey = cx + side * r * 0.36, cy - r * 0.05
      if mood == "happy" or mood == "win" then
        img:fill(gfx.shape():capsule(ex - 16, ey + 6, ex, ey - 10, 5):capsule(ex, ey - 10, ex + 16, ey + 6, 5), ink[1], ink[2], ink[3])
      elseif mood == "lose" then
        img:fill(gfx.shape():capsule(ex - 12, ey - 12, ex + 12, ey + 12, 5):capsule(ex - 12, ey + 12, ex + 12, ey - 12, 5), ink[1], ink[2], ink[3])
      elseif mood == "hurt" then
        img:fill(gfx.shape():capsule(ex - side * 14, ey - 10, ex + side * 6, ey, 5):capsule(ex + side * 6, ey, ex - side * 14, ey + 10, 5), ink[1], ink[2], ink[3])
      else
        local eye = gfx.shape():ellipse(ex, ey, r * 0.17, r * 0.23)
        img:fill(eye, ink[1], ink[2], ink[3], 255, { inset = -2.5 })
        img:fill(eye, 255, 255, 255)
        img:fill(gfx.shape():ellipse(ex - side * 3, ey + 6, r * 0.09, r * 0.13), ink[1], ink[2], ink[3])
        img:fill(gfx.shape():circle(ex - side * 3 - 4, ey, 4), 255, 255, 255)
        if mood == "worried" then
          img:fill(gfx.shape():capsule(ex - side * 18, ey - 40, ex + side * 14, ey - 30, 4), ink[1], ink[2], ink[3])
        end
      end
    end

    -- mouth
    local my = cy + r * 0.40
    if mood == "happy" or mood == "win" then
      local mouth = gfx.shape():ellipse(cx, my, 22, 16):rect(cx - 30, my - 30, 60, 30, 0, "sub")
      img:fill(mouth, ink[1], ink[2], ink[3])
      img:fill(gfx.shape():ellipse(cx, my + 9, 11, 6), 255, 120, 150)
    elseif mood == "worried" or mood == "hurt" or mood == "lose" then
      img:fill(gfx.shape():ellipse(cx, my + 4, 12, 9), ink[1], ink[2], ink[3])
    else
      img:fill(gfx.shape():capsule(cx - 12, my, cx, my + 7, 4):capsule(cx, my + 7, cx + 12, my, 4), ink[1], ink[2], ink[3])
    end

    -- a sweat drop when worried
    if mood == "worried" then
      local sx, sy = cx + r * 0.85, cy - r * 0.45
      local drop = gfx.shape():circle(sx, sy + 10, 12):poly { sx, sy - 20, sx - 11, sy + 4, sx + 11, sy + 4 }
      img:fill(drop, 40, 90, 160, 255, { soft = 1.2 })
      img:fill(drop, 150, 210, 255, 255, { inset = 2 })
    end
  end,

  -- Voices. Each entry may be a file ("chain1.ogg"), a list of files (for
  -- `chain`, one per link: the last one repeats), or a function that makes
  -- a sound itself. These use the built-in synth so no audio files needed.
  voice = {
    chain = function(n)
      local f = 392 * 2 ^ (math.min(n, 12) * 2 / 12)
      synth { wave = "square", duty = 0.25, freq = f, to = f * 1.5, dur = 0.10, vol = 0.14 }
      synth { wave = "square", duty = 0.25, freq = f * 1.5, dur = 0.16, vol = 0.12, delay = 0.09, vib = 0.3 }
    end,
    win = function()
      for i, n in ipairs { 0, 4, 7, 12 } do
        synth { wave = "triangle", freq = 523 * 2 ^ (n / 12), dur = 0.16, vol = 0.3, delay = (i - 1) * 0.08 }
      end
    end,
  },
}
