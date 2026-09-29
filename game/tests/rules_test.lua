-- Rules self-test. Runs inside the engine (`buyo-buyo --headless -- --test`)
-- or with plain Lua from the repo root:  lua game/tests/rules_test.lua
-- SPDX-License-Identifier: GPL-2.0-or-later
local modname = ...
if modname ~= "tests.rules_test" then
  package.path = "game/?.lua;" .. package.path
  sys = sys or { time = os.clock }
end

local Board = require "puyo.board"
local Rules = require "puyo.rules"
local Match = require "puyo.match"
local Sequence = require "puyo.sequence"
local AI = require "puyo.ai"
local U = require "core.util"

local SUB = Rules.SUB

return (function()
  local passed, failed = 0, 0
  local function check(name, cond, detail)
    if cond then
      passed = passed + 1
    else
      failed = failed + 1
      print("FAIL: " .. name .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
    end
  end

  local function run()
    local R = Rules.make()
    -- 1. single pop
    do
      local b = Board.from_rows { "R.....", "R.....", "R.....", "R....." }
      local ch, sc = b:resolve(R)
      check("single pop chain", ch == 1, ch)
      check("single pop score", sc == 40, sc)
      check("single pop empties board", b:is_empty())
    end
    -- 2. two-link chain: 40 + 10*4*8
    do
      local b = Board.from_rows { "G.....", "R.....", "RG....", "RG....", "RG...." }
      local ch, sc = b:resolve(R)
      check("2-chain length", ch == 2, ch)
      check("2-chain score", sc == 360, sc)
    end
    -- 3. nuisance next to a popping group is cleared, the rest falls
    do
      local b = Board.from_rows { ".O....", "RO....", "RO....", "RO....", "RO...." }
      local ch, sc = b:resolve(R)
      check("garbage chain", ch == 1, ch)
      check("garbage not scored", sc == 40, sc)
      check("far garbage survives", b:get(2, 1) == Rules.GARBAGE and b:get(2, 2) == 0)
    end
    -- 4. group bonus (5 puyos -> +2) and color bonus (2 colors -> +3)
    do
      local _, sc = Board.from_rows { "R.....", "R.....", "R.....", "RR...." }:resolve(R)
      check("group bonus", sc == 100, sc)
      _, sc = Board.from_rows { "RG....", "RG....", "RG....", "RG...." }:resolve(R)
      check("color bonus", sc == 240, sc)
    end
    -- 5. the hidden 13th row never pops
    do
      local rows = { "R.....", "R.....", "R.....", "R....." }
      for k = 1, 9 do rows[#rows + 1] = (k % 2 == 0) and "Y....." or "P....." end
      local b = Board.from_rows(rows)
      check("13 rows built", b:get(1, 13) == 1 and b:get(1, 10) == 1)
      check("hidden row does not pop", b:find_groups(R.pop) == nil)
    end
    -- 6. rules tables and overrides
    do
      check("chain power 2", R.cp[2] == 8)
      check("chain power 19", R.cp[19] == 512)
      check("link score", Rules.link_score(R, 1, 4, 1, { 4 }) == 40)
      check("group bonus 11+", R.gb[11] == 10 and R.gb[30] == 10)
      check("margin", Rules.target_points(R, 0) == 70 and Rules.target_points(R, R.margin_time) == 52)
      local R3 = Rules.make({ pop = 3, colors = 9, gravity = 1.5 })
      check("override pop", R3.pop == 3)
      check("override clamped", R3.colors == 5 and math.type(R3.gravity) == "integer")
      local _, sc = Board.from_rows { "R.....", "R.....", "R....." }:resolve(R3)
      check("pop 3 mode", sc == 30, sc)
    end
    -- 7. deterministic shared sequence
    do
      local a, b = Sequence.new(42, 4), Sequence.new(42, 4)
      local same, legal = true, true
      local allowed = {}
      for _, c in ipairs(a.palette) do allowed[c] = true end
      for n = 1, 200 do
        local p, q = a:get(n), b:get(n)
        if p[1] ~= q[1] or p[2] ~= q[2] then same = false end
        if not allowed[p[1]] or not allowed[p[2]] then legal = false end
      end
      check("sequence deterministic", same)
      check("sequence uses palette", legal)
      local st = a:save()
      local before = a:get(300)[1] .. a:get(300)[2]
      a:load(st)
      check("sequence restore", a:get(300)[1] .. a:get(300)[2] == before)
    end
    -- 8. rotation: wall kicks, floor kick, quick turn
    do
      local function mk()
        local m = Match.new { seed = 1 }
        local p = m.players[1]
        p.piece = { x = 3, y = 8 * SUB, r = 0, c1 = 1, c2 = 2, ang = 0, tang = 0 }
        return p
      end
      local p = mk()
      p.piece.x = 6
      p:rotate(1)
      check("right wall kick", p.piece.x == 5 and p.piece.r == 1)
      p = mk()
      p.piece.x = 1
      p:rotate(-1)
      check("left wall kick", p.piece.x == 2 and p.piece.r == 3)
      p = mk()
      p.piece.y, p.piece.r = SUB, 1
      p:rotate(1)
      check("floor kick", p.piece.r == 2 and p.piece.y == 2 * SUB)
      p = mk()
      for y = 1, 12 do
        p.board:set(2, y, (y % 2) + 3)
        p.board:set(4, y, (y % 2) + 3)
      end
      p.piece.y = 10 * SUB
      local first = p:rotate(1)
      check("well blocks rotation", not first and p.piece.r == 0)
      p:rotate(1)
      check("quick turn flips", p.piece.r == 2)
    end
    -- 9. AI simulator agrees with the reference implementation
    do
      local rng = U.rng(99)
      local agree, chains = true, 0
      for _ = 1, 400 do
        local b = Board.new()
        for x = 1, 6 do
          for y = 1, rng:int(0, 11) do
            b:set(x, y, rng:int(1, 10) == 1 and Rules.GARBAGE or rng:int(1, 4))
          end
        end
        local flat = table.move(b.c, 1, Board.N, 1, {})
        local ch1, sc1 = b:resolve(R)
        local ch2, sc2 = AI.simulate(flat, R)
        if ch1 ~= ch2 or sc1 ~= sc2 then agree = false end
        for i = 1, Board.N do
          if flat[i] ~= b.c[i] then agree = false end
        end
        if ch1 > 1 then chains = chains + 1 end
      end
      check("AI simulate == Board:resolve", agree)
      check("random boards produced chains", chains > 5, chains)
    end
    -- 10. AI produces a legal plan
    do
      local m = Match.new { seed = 7 }
      local p = m.players[1]
      p:spawn()
      local ai = AI.new(4, 1)
      local co = coroutine.create(function() return ai:plan(p, m) end)
      local plan
      for _ = 1, 100 do
        local ok, res = coroutine.resume(co)
        assert(ok, res)
        if coroutine.status(co) == "dead" then plan = res break end
      end
      check("AI produced a plan", plan and plan.x >= 1 and plan.x <= 6 and plan.r >= 0 and plan.r <= 3)
    end

    print(string.format("rules self-test: %d passed, %d failed", passed, failed))
    return failed == 0
  end

  if modname == "tests.rules_test" then return run end
  os.exit(run() and 0 or 1)
end)()
