-- Sound effects, synthesized on the fly by the C synth (see audio.play).
local Sound = {}

local play = audio.play
local S = {}
local last = {}
local frame = 0

-- rising scale for chain pops
local POP_STEPS = { 0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19, 21, 23, 24 }

function S.move(pan)
  play { wave = "square", duty = 0.25, freq = 900, dur = 0.028, vol = 0.10, pan = pan, release = 0.012 }
end

function S.rotate(pan)
  play { wave = "triangle", freq = 640, to = 1250, dur = 0.06, vol = 0.34, pan = pan, release = 0.03 }
end

function S.lock(pan)
  play { wave = "triangle", freq = 200, to = 95, dur = 0.08, vol = 0.40, pan = pan, release = 0.04 }
  play { wave = "noise", freq = 3200, dur = 0.04, vol = 0.07, pan = pan, decay = 40 }
end

function S.land(pan)
  play { wave = "sine", freq = 260, to = 120, dur = 0.06, vol = 0.30, pan = pan, release = 0.03 }
end

function S.harddrop(pan)
  play { wave = "noise", freq = 2600, to = 500, dur = 0.14, vol = 0.22, decay = 16, pan = pan }
  play { wave = "sine", freq = 170, to = 55, dur = 0.16, vol = 0.55, pan = pan, release = 0.05 }
end

function S.pop(pan, chain)
  local n = POP_STEPS[math.min(chain or 1, #POP_STEPS)]
  local f = 523.25 * 2 ^ (n / 12)
  play { wave = "square", duty = 0.5, freq = f, to = f * 1.5, dur = 0.09, vol = 0.20, pan = pan, release = 0.04 }
  play { wave = "square", duty = 0.25, freq = f * 1.5, to = f * 2, dur = 0.14, vol = 0.16, delay = 0.07, pan = pan, release = 0.07 }
  play { wave = "triangle", freq = f * 2, dur = 0.20, vol = 0.22, delay = 0.12, pan = pan, release = 0.12, vib = 0.3, vibrate = 12 }
  play { wave = "noise", freq = 14000, dur = 0.16, vol = 0.07, decay = 20, pan = pan }
end

function S.send(pan, n)
  local big = (n or 0) >= 30
  play { wave = "noise", freq = 1800, to = 12000, dur = 0.30, vol = big and 0.20 or 0.14, decay = 5, pan = pan }
  play { wave = "saw", freq = 200, to = 900, dur = 0.24, vol = 0.10, pan = pan, release = 0.08 }
end

function S.offset(pan)
  play { wave = "square", duty = 0.125, freq = 1400, to = 700, dur = 0.14, vol = 0.14, pan = pan, release = 0.06 }
  play { wave = "noise", freq = 9000, to = 2500, dur = 0.20, vol = 0.10, decay = 10, pan = pan }
end

function S.garbage(pan, n)
  local big = (n or 0) >= 12
  play { wave = "sine", freq = big and 120 or 170, to = 40, dur = big and 0.40 or 0.22, vol = 0.8, pan = pan, release = 0.1 }
  play { wave = "noise", freq = 1400, to = 300, dur = big and 0.4 or 0.25, vol = big and 0.28 or 0.15, decay = 9, pan = pan }
end

function S.all_clear(pan)
  for i, n in ipairs { 0, 4, 7, 12, 16, 19, 24 } do
    play { wave = "square", duty = 0.25, freq = 523.25 * 2 ^ (n / 12), dur = 0.14, vol = 0.16,
           delay = (i - 1) * 0.06, pan = pan, release = 0.07 }
  end
end

function S.die(pan)
  play { wave = "square", duty = 0.5, freq = 700, to = 70, dur = 1.0, vol = 0.22, vib = 0.9, vibrate = 9, pan = pan, release = 0.25 }
  play { wave = "noise", freq = 900, to = 200, dur = 0.8, vol = 0.12, decay = 3, pan = pan }
end

function S.menu_move()
  play { wave = "square", duty = 0.25, freq = 1000, dur = 0.035, vol = 0.12, release = 0.015 }
end

function S.menu_ok()
  play { wave = "square", duty = 0.25, freq = 784, dur = 0.06, vol = 0.14 }
  play { wave = "square", duty = 0.25, freq = 1175, dur = 0.12, vol = 0.14, delay = 0.06, release = 0.06 }
end

function S.menu_back()
  play { wave = "square", duty = 0.25, freq = 700, to = 420, dur = 0.10, vol = 0.12, release = 0.04 }
end

function S.ready()
  play { wave = "square", duty = 0.5, freq = 880, dur = 0.14, vol = 0.14, release = 0.06 }
end

function S.go()
  play { wave = "square", duty = 0.5, freq = 1760, dur = 0.32, vol = 0.16, release = 0.16 }
  play { wave = "triangle", freq = 880, dur = 0.32, vol = 0.3, release = 0.16 }
end

function S.danger(pan)
  play { wave = "square", duty = 0.5, freq = 1250, dur = 0.05, vol = 0.05, pan = pan }
end

-- throttle: the same sound on the same side at most once every 3 frames
function Sound.play(name, pan, arg)
  local f = S[name]
  if not f then return end
  local key = name .. (pan or 0)
  if last[key] and frame - last[key] < 3 then return end
  last[key] = frame
  f(pan or 0, arg)
end

function Sound.tick() frame = frame + 1 end

return Sound
