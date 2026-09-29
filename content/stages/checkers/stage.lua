-- An image-based stage: no code at all, just PNG layers with parallax.
-- Full reference: docs/STAGES.md
return {
  name = "Checkers",
  author = "Buyo Buyo",
  order = 2,
  music = "battle",
  gradient = { top = { 22, 70, 110 }, bottom = { 10, 18, 44 } },
  layers = {
    -- back to front; x/y scroll speeds are pixels per frame
    { image = "tile.png", tile = true, scale = 2, scroll_x = -0.15, scroll_y = 0.05, alpha = 26 },
    { image = "tile.png", tile = true, scroll_x = 0.35, scroll_y = 0.18, alpha = 46 },
  },
}
