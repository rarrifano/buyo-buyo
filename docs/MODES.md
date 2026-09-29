# Game modes

A mode changes **the rules of the match**: speed, scoring, how nuisance
works, even how you win. It is a folder `modes/<id>/` with a `mode.lua`.
Players pick the mode on the match screen after choosing characters.

Modes come in two flavours, and you can mix them:

- **Rules only** - no code, just numbers (`content/modes/speed/`).
- **Hooks** - small functions the engine calls at key moments
  (`content/modes/nuisance_rain/`).

## Without code

A folder with an `info.txt` is a mode - every rule from the table below can
be set in plain text:

```
name = Fast Five
description = Five colors, fast drops, cheap nuisance.
colors = 5
gravity = 80
target_points = 50
```

Hooks (functions that react to the match) need a `mode.lua`. See
[the no-code guide](GETTING_STARTED.md#2-no-code-needed-just-drop-in-files).

## Rules only

```lua
return {
  name = "Five Alive",
  author = "you",
  description = "Five colors and it takes five to pop.",
  order = 10,
  rules = { colors = 5, pop = 5, target_points = 50 },
}
```

Every rule you leave out keeps its default. The player's **FIRST TO**
choice on the match screen always wins over `rules.first_to`; `colors` in
a mode overrides the player's COLORS setting.

### All rules

Times are in frames (60 per second). Speeds use sub-rows: **1024 = one
row**, so `gravity = 28` is about 1/37 of a row per frame.

| Rule | Default | Meaning |
|---|---|---|
| `colors` | 4 | colors in play (3..5) |
| `pop` | 4 | puyos needed to pop (2..12) |
| `spawn_x` | 3 | column where pairs appear (1..6) |
| `death_x`, `death_y` | 3, 12 | the X: if this cell is filled when a new pair should appear, you lose |
| `target_points` | 70 | score points per nuisance puyo sent (lower = more nuisance) |
| `max_drop` | 30 | most nuisance that falls at once (30 = 5 rows) |
| `all_clear_garbage` | 30 | bonus nuisance added to the next chain after clearing the field |
| `all_clear_score` | 2100 | bonus score for an all clear |
| `margin_time` | 5760 (96 s) | when nuisance starts getting cheaper |
| `margin_step` | 960 (16 s) | every step after that, target points x 3/4 |
| `das` | 9 | frames holding left/right before auto-repeat |
| `arr` | 2 | frames between auto-repeat steps |
| `gravity` | 28 | falling speed, sub-rows per frame (1..1023) |
| `soft_drop` | 512 | falling speed while holding down |
| `lock_delay` | 30 | frames a resting pair waits before locking |
| `lock_resets` | 10 | moves/rotations allowed to reset the lock timer |
| `floor_kicks` | 8 | times a pair may be pushed up by rotating against the floor |
| `quick_turn` | 18 | double-tap window for the 180 degree flip in a narrow well |
| `pop_time` | 42 | how long popping puyos flash |
| `fall_accel`, `fall_max` | 46, 922 | falling animation speed of settling puyos |
| `spawn_delay` | 8 | pause before the next pair appears |
| `ready_time` | 150 | the READY? GO! countdown |
| `over_time` | 220 | pause after a round |
| `first_to` | 2 | rounds to win the match |
| `hard_drop` | true | allow hard drop at all |
| `chain_power` | 0, 8, 16, 32, 64, 96 ... 512 | score multiplier for chain link 1, 2, 3 ... |
| `color_bonus` | 0, 3, 6, 12, 24 | bonus for popping 1..5 colors at once |
| `group_bonus` | [5]=2 [6]=3 ... [11]=10 | bonus for big groups (by size) |

Score of a chain link = `10 x puyos x max(1, chain power + color bonus + group bonus)`
(capped at 999). Nuisance sent = score / `target_points`, carrying the
remainder over. Bad values are clamped, so a typo can't crash the game.

## Hooks

Add functions to the table and the engine calls them. `m` is the match,
`p` a player (see [the API below](#what-hooks-can-use)).

| Hook | Called | Return |
|---|---|---|
| `init(m)` | once, when the match is created | - |
| `round_start(m)` | at the start of every round (fields are empty) | - |
| `frame(m)` | every frame while a round is played, after both players moved | - |
| `link(m, p, link)` | every chain link, before nuisance is sent | the link (modified or not) |
| `chain_end(m, p, chain)` | when a chain finishes (`chain` = its length) | - |
| `pair(m, p, pair)` | when a new pair appears (`pair = { pivot color, other color }`) | the pair |
| `garbage(m, p, n)` | right before `n` nuisance falls on `p` | how many fall instead |
| `winner(m)` | every frame of a round | `1` or `2` to end the round with that winner, `0` for a draw, `nil` to keep playing |
| `hud(m, gfx, x, y)` | every frame, to draw extra info in the middle column (visual only) | - |

The `link` table has: `chain` (link number), `score`, `bonus`, `puyos`
(how many popped), `colors`, `garbage` (nuisance this link sends),
`leftover` (score carried to the next link) and `all_clear` (true if this
link includes the all-clear bonus). Change what you like and return it.

### Example: rain, bonuses and a HUD

```lua
local EVERY = 20 * 60 -- constants at file level are fine

return {
  name = "Nuisance Rain",
  rules = { first_to = 2 },

  round_start = function(m)
    m.data.next = EVERY                     -- mode state lives in m.data
  end,

  frame = function(m)
    if m.frames >= m.data.next then
      m.data.next = m.data.next + EVERY
      for _, p in ipairs(m.players) do p:add_garbage(6) end
      m:emit(nil, "announce", { text = "RAIN!", color = { 150, 200, 255 } })
    end
  end,

  hud = function(m, gfx, x, y)
    local left = math.max(0, m.data.next - m.frames)
    gfx.color(150, 200, 255)
    gfx.text(string.format("RAIN IN %2d", left // 60), x, y, 2, "center")
  end,
}
```

### More recipes

```lua
-- Only real chains attack: single pops and doubles send nothing.
link = function(m, p, link)
  if link.chain < 3 then link.garbage = 0 end
  return link
end,

-- Nuisance is halved (rounded up).
garbage = function(m, p, n) return (n + 1) // 2 end,

-- Sudden death: after 2 minutes the higher score wins.
winner = function(m)
  if m.frames >= 2 * 60 * 60 then
    local a, b = m.players[1].score, m.players[2].score
    if a > b then return 1 elseif b > a then return 2 else return 0 end
  end
end,

-- One pair in ten is a double (both halves the same color).
pair = function(m, p, pair)
  if m.rng:int(1, 10) == 1 then pair[2] = pair[1] end
  return pair
end,

-- The game speeds up every 30 seconds.
frame = function(m)
  m.gravity = math.min(400, m.R.gravity + (m.frames // 1800) * 16)
end,
```

## Determinism

This is the one important rule of modes. In an online match **both
computers run the whole match themselves**, and when an input arrives late
they rewind a few frames and replay them (rollback). Your hooks run on
both machines, sometimes several times for the same frame, and must
always produce exactly the same result from the same situation.

Do:

- Read and write only the match (`m`), the players (`p`) and `m.data`.
- Keep **all mode state in `m.data`** (plain tables, numbers, strings,
  booleans). It is saved and restored with the rest of the match.
- Use `m.rng:int(a, b)` for randomness. It is seeded identically on both
  machines and rewinds correctly.
- Prefer integers (`//`, `math.floor`) over fractions.

Don't:

- Don't keep changing state in variables outside `m.data` (a `local
  counter` at the top of the file that you increment). It won't be
  rewound, and the two machines drift apart.
- Don't use time, `math.random` (it's not even available in modes) or
  anything that differs per machine.
- Don't change anything in `hud` - it's for drawing only, and it's not
  called during replays.
- Don't rely on the order of `pairs()` over a table; iterate arrays with
  `ipairs` or numeric loops.

If you break these rules, online matches report a **DESYNC** (the game
detects it with checksums) instead of silently diverging.

## What hooks can use

**Match `m`**

| Field / method | |
|---|---|
| `m.R` | the rules table (read) |
| `m.frames` | frames played in this round |
| `m.round`, `m.wins[1]`, `m.wins[2]` | round number and score |
| `m.players[1]`, `m.players[2]` | the players |
| `m.data` | your mode's own state (saved/restored for you) |
| `m.rng:int(a, b)` | deterministic random integer in a..b |
| `m.target_points` | current score points per nuisance (after margin time) |
| `m.gravity` | current falling speed (sub-rows per frame, keep it 1..1023); reset every round |
| `m.state` | `"ready"`, `"play"`, `"over"` or `"done"` |
| `m:attack(p, n)` | make `p` send `n` nuisance (offsets `p`'s own incoming first) |
| `m:emit(nil, "announce", { text = "...", color = {r,g,b} })` | show a big message (visual only) |

**Player `p`**

| Field / method | |
|---|---|
| `p.id` | 1 or 2 |
| `p.opponent` | the other player |
| `p.score`, `p.sent` | score and nuisance sent this round |
| `p.pending` | nuisance waiting to fall on this player |
| `p:add_garbage(n)` | add `n` to `p.pending` |
| `p.chain`, `p.chaining`, `p.max_chain` | current chain link, whether a chain is running, best chain |
| `p.all_clear` | an all-clear bonus is waiting to be used |
| `p.dead` | topped out |
| `p.state` | `"wait"`, `"spawn_wait"`, `"move"`, `"fall"`, `"pop"`, `"garbage"`, `"dead"` |
| `p.piece` | the falling pair while `state == "move"`: `x`, `y` (sub-rows), `r` (rotation 0-3), `c1`, `c2` |
| `p.board:get(x, y)`, `p.board:set(x, y, v)`, `p.board:height(x)` | the field |

The field is 6 columns (`x` 1..6, left to right) by 13 rows (`y` 1..13,
bottom to top; row 13 is the hidden row above the screen). Cell values: `0`
empty, `1`-`5` colors, `6` nuisance. If you place cells yourself, keep
columns packed from the bottom (no holes), or they will float until the
next chain.

## Modes and online play

The host chooses the mode. The guest must have **the very same mode file**
(same id and identical content) - the game compares a fingerprint of
`mode.lua` and refuses to start otherwise, because different rules would
desync. Share modes as files; don't edit a mode someone else is using
online without renaming it.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Mode missing | See **CONTENT -> ERRORS**. Unknown hook names are reported (typo in `round_start`?). |
| `hook 'frame' failed and was disabled` | Your hook raised an error. The message and line are in ERRORS; the match continues without that hook. |
| `attempt to call a nil value (field 'random')` | `math.random` doesn't exist in modes; use `m.rng:int(a, b)`. |
| Online: "you don't have the same mode" | Both players need identical files. Copy the host's `mode.lua`. |
| Online: DESYNC | A hook isn't deterministic - see [Determinism](#determinism). |

Test a mode quickly: `buyo-buyo -- --mode watch --game-mode my_mode` runs
a CPU vs CPU match with it, and `--check-content` smoke-tests every mode.
