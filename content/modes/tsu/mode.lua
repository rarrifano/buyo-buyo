-- The standard ruleset (4 colors, pop 4, Tsu-style scoring, margin time).
-- A mode with no overrides and no hooks is exactly the engine defaults.
-- Full reference: docs/MODES.md
return {
  name = "Standard",
  author = "Buyo Buyo",
  description = "Classic Tsu-style rules. Four to pop, offset nuisance, margin time after 96 seconds.",
  order = 1,
  rules = {},
}
