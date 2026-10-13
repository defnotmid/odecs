-- Palette, type and the small parts the scenes share.

local beat = require("beat")

local M = {}

M.BG, M.PANEL, M.LINE = "#0b0806", "#17120e", "#3a2e24"
M.TEXT, M.DIM = "#fff4e6", "#a8957f"
M.A, M.B, M.C = "#ffb020", "#2fe0c0", "#ff5a4e" -- amber, teal, coral

M.DISPLAY, M.SANS, M.MONO = "Bebas Neue", "Space Grotesk", "JetBrains Mono"

-- A filled label, popping from its left edge.
function M.chip(x, y, label, fill, ink, size, pop)
  size = size or 22
  local w = text_width { label, font = M.MONO, size = size } + size * 1.4
  local h = size * 1.9
  group({ transform = { scale = pop or 1, origin = { x, y + h / 2 } } }, function()
    rect { x = x, y = y, w = w, h = h, rx = h / 2, fill = fill }
    text { label, x = x + size * 0.7, y = y + h / 2, baseline = "middle", font = M.MONO, size = size, fill = ink or M.BG }
  end)
  return w
end

-- The section label top left, popping on its first beat.
function M.label(lb, n, s)
  M.chip(120, 120, string.format("%02d · %s", n, s), M.LINE, M.TEXT, 24, beat.snap(lb))
end

-- A fact line at the bottom: what, and where the number comes from.
function M.fact(lb, at, s, source)
  local p = beat.snap(lb - at)
  if lb < at then return end
  group({ opacity = beat.prog(lb, at, at + 0.2), transform = translate(0, (1 - p) * 30) }, function()
    text { s, x = 120, y = 960, font = M.SANS, size = 40, fill = M.TEXT }
    text { source, x = 120, y = 1004, font = M.MONO, size = 20, fill = M.DIM }
  end)
end

-- The soundtrack's spectrum at the frame as `n` levels from 0 to 1: bins
-- of a 512-sample FFT grouped on a log scale, in decibels from -20 to +26
-- (why_onimite/ui.lua).
local BAND_BINS = {}
local function band_bins(n)
  if not BAND_BINS[n] then
    local edges = {}
    for i = 0, n do edges[i] = math.floor(2 ^ (i / n * 7) + 0.5) end -- bins 1..128
    BAND_BINS[n] = edges
  end
  return BAND_BINS[n]
end

function M.spectrum(f, n)
  local bins = audio_spectrum(f.global_index / beat.FPS, { src = "track.wav", sample_size = 512, smooth = 2,
    window = "hann" }) or {}
  local edges, out = band_bins(n), {}
  for i = 1, n do
    local lo, hi = edges[i - 1], math.max(edges[i], edges[i - 1] + 1)
    local sum = 0
    for k = lo, hi - 1 do sum = sum + (bins[k + 1] or 0) end
    local db = 20 * math.log(sum / (hi - lo) + 1e-3, 10)
    out[i] = beat.clamp01((db + 20) / 46)
  end
  return out
end

return M
