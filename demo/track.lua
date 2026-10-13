-- The soundtrack, synthesized when the script loads (the instruments are
-- onimite/examples/why_onimite/track.lua's): 120 BPM broken beat in E minor
-- (Em C G D, a chord a bar), 13 bars arranged like the scenes, its hits on
-- the beats timeline.lua gives the picture. build() returns a 16-bit stereo
-- 48 kHz WAV as a string; video.lua runs it once per render through
-- shared() and audio_add().

local beat = require("beat")
local T = require("timeline")

local M = {}

-- ---- this song -------------------------------------------------------------

local CHORDS = { { 52, 55, 59, 64 }, { 48, 52, 55, 60 }, { 55, 59, 62, 67 }, { 50, 54, 57, 62 } }
local ROOTS = { 40, 36, 43, 38 }
local KICKS = { 0, 1.5, 2.5 }  -- beats in the bar
local CLAPS = { 1, 3 }
local SEED = 120

-- What plays in each bar: k kick, c clap, h hats (x: sixteenths), o open
-- hats on the off-beats, b bass, s stabs, a arp, p pad.
local BARS = {
  [0] = "xp", "kxbp",                 -- title: the slam on bar 1
  "kcxbs", "kcxbs", "kcxbsa",         -- alpha video
  "hpa", "hpa",                       -- webp: breakdown over the panorama
  "kcxob", "kcxob", "kcxobs",         -- encode, decode
  "kcxobsa", "kcxobsa", "p",          -- outro, then the tail
}

-- ---- the synth ---------------------------------------------------------------

local RATE = 48000
local BEAT = beat.BEAT
local sin, exp, floor, abs, min, random = math.sin, math.exp, math.floor, math.abs, math.min, math.random
local TAU = 2 * math.pi

local function midi(n) return 440 * 2 ^ ((n - 69) / 12) end
-- One-pole low-pass coefficient for a cutoff in Hz.
local function lp(hz) return 1 - exp(-TAU * hz / RATE) end
local function noise() return random() * 2 - 1 end

local L, R, N
local kick_on = {} -- sixteenth index -> true where a kick plays

-- The samples a sound starting at t0 for dur seconds covers.
local function span(t0, dur)
  return floor(t0 * RATE) + 1, min(N, floor((t0 + dur) * RATE))
end

-- Sidechain: bass and chords dip under every kick.
local function duck(t)
  local s = floor(t / (BEAT / 4))
  for back = 0, 3 do
    if kick_on[s - back] then return 1 - 0.8 * exp(-(t - (s - back) * BEAT / 4) / 0.07) end
  end
  return 1
end

local function add(i, v, pan)
  L[i] = L[i] + v * (1 - pan)
  R[i] = R[i] + v * (1 + pan)
end

-- A sine with a fast pitch drop and an exponential decay, plus a click.
local function kick(t0, gain)
  local a, b = span(t0, 0.4)
  local ph = 0
  for i = a, b do
    local t = (i - a) / RATE
    ph = ph + TAU * (48 + 130 * exp(-t * 30)) / RATE
    add(i, (sin(ph) * exp(-t * 7) + noise() * exp(-t * 600) * 0.25) * gain, 0)
  end
end

-- Three quick high-passed noise bursts and a tail, over a short tone body.
local function clap(t0, gain)
  local a, b = span(t0, 0.3)
  local prev, ph = 0, 0
  for i = a, b do
    local t = (i - a) / RATE
    local x = noise()
    local hp = x - prev
    prev = x
    local bursts = t < 0.033 and exp(-(t % 0.011) * 300) or 0
    ph = ph + TAU * 185 / RATE
    add(i, (hp * (bursts * 0.7 + exp(-t * 16) * 0.5) * 0.6 + sin(ph) * exp(-t * 30) * 0.5) * gain, -0.05)
  end
end

-- Twice high-passed noise; crashes are long open hats.
local function hat(t0, dur, decay, gain)
  local a, b = span(t0, dur)
  local p1, p2 = 0, 0
  for i = a, b do
    local t = (i - a) / RATE
    local x = noise()
    local h1 = x - p1
    local h2 = h1 - p2
    p1, p2 = x, h1
    add(i, h2 * 0.25 * exp(-t * decay) * gain, 0.12)
  end
end

-- A saw (and a sine an octave down) through a one-pole low-pass, ducked.
local function bass(t0, dur, note, gain)
  local a, b = span(t0, dur)
  local f = midi(note) / RATE
  local ph, y, k = 0, 0, lp(420)
  for i = a, b do
    local t = (i - a) / RATE
    ph = ph + f
    if ph >= 1 then ph = ph - 1 end
    y = y + k * (2 * ph - 1 - y)
    local env = min(1, t * 400, (b - i) / 480)
    add(i, (y + sin(TAU * ph) * 0.6) * env * gain * duck(t0 + t), 0)
  end
end

-- Detuned saw pairs, one side tuned up and the other down, low-passed and
-- ducked: short decays make stabs, slow attacks pads.
local function chord(t0, dur, notes, gain, cutoff, attack, decay)
  local a, b = span(t0, dur)
  local k = lp(cutoff)
  for _, n in ipairs(notes) do
    local f1, f2 = midi(n) * 1.006 / RATE, midi(n) / 1.006 / RATE
    local p1, p2, yl, yr = random(), random(), 0, 0
    for i = a, b do
      local t = (i - a) / RATE
      p1 = p1 + f1
      if p1 >= 1 then p1 = p1 - 1 end
      p2 = p2 + f2
      if p2 >= 1 then p2 = p2 - 1 end
      yl = yl + k * (2 * p1 - 1 + p2 - 0.5 - yl)
      yr = yr + k * (2 * p2 - 1 + p1 - 0.5 - yr)
      local env = min(1, t / attack, (b - i) / 2400) * exp(-t * decay) * gain * duck(t0 + t)
      L[i] = L[i] + yl * env
      R[i] = R[i] + yr * env
    end
  end
end

-- A low-passed square pluck for the arp.
local function pluck(t0, note, gain, pan)
  local a, b = span(t0, 0.18)
  local f = midi(note) / RATE
  local ph, y, k = 0, 0, lp(2500)
  for i = a, b do
    local t = (i - a) / RATE
    ph = ph + f
    if ph >= 1 then ph = ph - 1 end
    y = y + k * ((ph < 0.5 and 1 or -1) - y)
    add(i, y * exp(-t * 16) * gain * duck(t0 + t), pan)
  end
end

-- Noise through an opening low-pass and a rising sine, swelling into a drop.
local function riser(t0, dur, gain)
  local a, b = span(t0, dur)
  local y, ph = 0, 0
  for i = a, b do
    local u = (i - a) / RATE / dur
    y = y + lp(300 + 9000 * u * u) * (noise() - y)
    ph = ph + TAU * (180 + 900 * u * u) / RATE
    add(i, (y * 0.8 + sin(ph) * 0.15) * u * u * gain, 0)
  end
end

-- The big hit: a falling sub boom and a burst of dark noise, saturated.
local function impact(t0, gain)
  local a, b = span(t0, 2.5)
  local ph, y, k = 0, 0, lp(900)
  for i = a, b do
    local t = (i - a) / RATE
    ph = ph + TAU * (30 + 70 * exp(-t * 6)) / RATE
    y = y + k * (noise() - y)
    local v = (sin(ph) * exp(-t * 1.6) + y * 1.5 * exp(-t * 4)) * gain
    add(i, v / (1 + abs(v)) * 1.6, 0)
  end
end

-- A beat of stutter: 32nd-note grains of square tone and noise at hashed
-- pitches, bouncing left and right.
local function glitch(t0, gain)
  local grain = BEAT / 8
  for g = 0, 7 do
    local a, b = span(t0 + g * grain, grain * 0.7)
    local f = midi(72 + floor(beat.hash(g + t0) * 24)) / RATE
    local ph, pan = 0, g % 2 == 0 and -0.6 or 0.6
    for i = a, b do
      ph = ph + f
      if ph >= 1 then ph = ph - 1 end
      add(i, ((ph < 0.5 and 0.5 or -0.5) + noise() * 0.3) * gain, pan)
    end
  end
end

local function blip(t0, hz, gain)
  local a, b = span(t0, 0.09)
  for i = a, b do
    local t = (i - a) / RATE
    add(i, (sin(TAU * hz * t) + 0.3 * sin(TAU * 2 * hz * t)) * exp(-t * 45) * gain, 0)
  end
end

local function at(b) return b * BEAT end
local function crash(b) hat(at(b), 1.6, 2.5, 0.9) end

local function play_bar(bar)
  local p = BARS[bar]
  local has = function(c) return p:find(c, 1, true) ~= nil end
  local i = bar % 4 + 1
  local notes, root, b0 = CHORDS[i], ROOTS[i], bar * 4
  for s = 0, 15 do
    if kick_on[b0 * 4 + s] then kick(at(b0 + s / 4), 0.9) end
  end
  if has("c") then for _, q in ipairs(CLAPS) do clap(at(b0 + q), 0.45) end end
  for e = 0, 7 do -- eighths
    local t = at(b0 + e / 2)
    if has("o") and e % 2 == 1 then hat(t, 0.22, 14, 0.3)
    elseif has("h") then hat(t, 0.045, 90, has("k") and 0.35 or 0.3) end
    if has("s") and (e == 0 or e == 3 or e == 6) then
      chord(t, BEAT * 0.45, { notes[1] + 12, notes[2] + 12, notes[3] + 12, notes[4] + 12 }, 0.04, 2600, 0.003, 7)
    end
  end
  for s = 0, 15 do -- sixteenths
    local t = at(b0 + s / 4)
    if has("x") then hat(t, 0.04, 110, s % 4 == 2 and 0.4 or 0.22) end
    if has("b") and s % 4 ~= 0 then bass(t, BEAT / 4 * 0.85, root + (s % 4 == 2 and 12 or 0), 0.22) end
    if has("a") then
      local pick = ({ 1, 2, 3, 4, 3, 2, 3, 4 })[s % 8 + 1]
      pluck(t, notes[pick] + 12, has("k") and 0.05 or 0.09, s % 2 == 0 and -0.4 or 0.4)
    end
  end
  if has("p") then
    chord(at(b0), BEAT * 4, notes, has("k") and 0.025 or 0.12, has("k") and 900 or 700, 0.3, 0)
  end
end

-- ---- the arrangement: hits on the picture's beats -----------------------------

local function hits()
  glitch(at(T.TITLE), 0.1)
  for k = 0, 7 do blip(at(T.TITLE + k / 2), 520 + k * 60, 0.08) end
  riser(at(T.TITLE + 2), 2 * BEAT, 0.3)
  impact(at(T.TITLE + T.TITLE_SLAM), 1.0)
  crash(T.ALPHA)
  for _, b in ipairs(T.ALPHA_FACTS) do
    blip(at(T.ALPHA + b), 1320, 0.16)
    blip(at(T.ALPHA + b + 0.25), 1980, 0.16)
  end
  crash(T.WEBP)
  blip(at(T.WEBP + T.WEBP_FACT), 1320, 0.16)
  riser(at(T.ENCODE - 2), 2 * BEAT, 0.3)
  crash(T.ENCODE)
  for _, b in ipairs(T.SHRINKS) do glitch(at(T.ENCODE + b), 0.08) end
  crash(T.ENCODE + 4)
  crash(T.ENCODE + 8)
  riser(at(T.OUTRO - 4), 4 * BEAT, 0.35)
  impact(at(T.OUTRO), 1.0)
  crash(T.OUTRO + T.WORDMARK)
  -- the tail: one long chord over a last kick and crash
  kick(at(T.END), 0.9)
  crash(T.END)
  chord(at(T.END), 2, { 40, 52, 55, 59, 64 }, 0.05, 2200, 0.003, 1.6)
end

-- ---- render ------------------------------------------------------------------

function M.build()
  math.randomseed(SEED)
  N = floor(T.TOTAL * BEAT * RATE)
  L, R = {}, {}
  for i = 1, N do L[i], R[i] = 0, 0 end

  -- kicks first: the sidechain needs them
  for bar = 0, #BARS do
    if BARS[bar]:find("k", 1, true) then
      for _, q in ipairs(KICKS) do kick_on[floor((bar * 4 + q) * 4 + 0.5)] = true end
    end
  end
  for bar = 0, #BARS do play_bar(bar) end
  hits()

  -- a gentle low-pass over the mix tames the naive saws' and noise's top
  -- end (inter-sample peaks), then normalize to -1 dBFS and pack as 16-bit
  local k, yl, yr = lp(11000), 0, 0
  for i = 1, N do
    yl = yl + k * (L[i] - yl)
    yr = yr + k * (R[i] - yr)
    L[i], R[i] = yl, yr
  end
  local peak = 0
  for i = 1, N do peak = math.max(peak, abs(L[i]), abs(R[i])) end
  local s = 0.89 / peak * 32767
  local FRAMES = 4096
  local full = "<" .. string.rep("i2", 2 * FRAMES)
  local chunks, buf = {}, {}
  for first = 1, N, FRAMES do
    local m = min(FRAMES, N - first + 1)
    for j = 0, m - 1 do
      buf[2 * j + 1] = floor(L[first + j] * s + 0.5)
      buf[2 * j + 2] = floor(R[first + j] * s + 0.5)
    end
    local fmt = m == FRAMES and full or "<" .. string.rep("i2", 2 * m)
    chunks[#chunks + 1] = string.pack(fmt, table.unpack(buf, 1, 2 * m))
  end
  L, R = nil, nil
  local data = table.concat(chunks)
  return string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 2,
    RATE, RATE * 4, 4, 16, "data", #data) .. data
end

return M
