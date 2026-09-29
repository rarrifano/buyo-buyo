-- A rules-only mode: no code, just different numbers.
-- Every key of RULES can be changed (see docs/MODES.md for the list).
return {
  name = "Speed",
  author = "Buyo Buyo",
  description = "Faster falling, snappier locks, cheaper nuisance and margin time after 30 seconds.",
  order = 2,
  rules = {
    gravity = 64, -- sub-rows per frame (1024 = one row): ~2.3x faster
    das = 7,
    lock_delay = 18,
    pop_time = 30,
    spawn_delay = 4,
    target_points = 60,
    margin_time = 30 * 60,
    margin_step = 12 * 60,
  },
}
