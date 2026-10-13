-- The musical clock (from onimite/examples/why_onimite/beat.lua). The
-- soundtrack (track.lua) is written on the same grid, so every cut and pop
-- lands on a beat by construction. Beat 0 is the first frame.

local M = {}

local floor, exp, sqrt, sin, cos = math.floor, math.exp, math.sqrt, math.sin, math.cos

M.FPS = 60
M.BPM = 120
M.BEAT = 60 / M.BPM -- seconds per beat

local BEAT, FPS = M.BEAT, M.FPS

function M.beat_time(beat) return beat * BEAT end

-- The frame a beat starts on, rounded so scene boundaries never drift.
function M.beat_frame(beat) return floor(beat * BEAT * FPS + 0.5) end

-- Position on the beat grid of the whole video.
function M.gbeat(f) return f.global_index / FPS / BEAT end

-- ---- easing, all on 0..1 ----------------------------------------------------

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end
M.clamp01 = clamp01

-- Where `x` is between `a` and `b`, clamped to 0..1.
function M.prog(x, a, b) return clamp01((x - a) / (b - a)) end

function M.lerp(a, b, t) return a + (b - a) * t end

function M.expo_out(t)
  t = clamp01(t)
  if t >= 1 then return 1 end
  return 1 - 2 ^ (-10 * t)
end

function M.expo_in(t)
  t = clamp01(t)
  if t <= 0 then return 0 end
  return 2 ^ (10 * t - 10)
end

-- Damped spring from 0 to 1 (mass 1), `t` in seconds since release.
local function spring(t, stiffness, damping)
  if t <= 0 then return 0 end
  local w0 = sqrt(stiffness)
  local zeta = damping / (2 * w0)
  if zeta < 1 then
    local wd = w0 * sqrt(1 - zeta * zeta)
    return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
  end
  return 1 - (1 + w0 * t) * exp(-w0 * t)
end

-- A snappy spring, `beats` since it was released on a beat.
function M.snap(beats) return spring(beats * BEAT, 320, 22) end
-- A softer spring with a visible overshoot.
function M.soft(beats) return spring(beats * BEAT, 170, 13) end

-- Decaying pulse that fires on every beat: 1 on the beat, ~0 half a beat later.
function M.pulse(beat, sharpness)
  if beat < 0 then return 0 end
  return exp(-(beat - floor(beat)) * sharpness)
end

-- Deterministic hash noise, 0..1.
function M.hash(n)
  local x = sin(n * 127.1 + 311.7) * 43758.547
  return x - floor(x)
end

return M
