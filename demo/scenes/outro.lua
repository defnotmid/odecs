-- The wordmark over the soundtrack's spectrum, then a bar of tail.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

local function render(f, lb)
  local fade = 1 - prog(lb, 9, 11.5)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
  local bands = spectrum_centered(ui.spectrum(f, 48))
  for i, v in ipairs(bands) do
    local h = v * 260 + 6
    rect { x = 72 + (i - 1) * 37.5, y = 1040 - h, w = 26, h = h, rx = 6, opacity = fade,
      fill = linear_gradient { x1 = 0, y1 = 0, x2 = 0, y2 = 1, units = "bbox", stops = { { 0, ui.A }, { 1, ui.C } } } }
  end
  local s = 1 + 0.3 * (1 - soft(lb)) + (lb < 8 and 0.02 * pulse(lb, 8) or 0)
  group({ opacity = fade, transform = { scale = s, origin = { 960, 420 } },
    shadow = { dx = 0, dy = 16, blur = 20, color = "#000000", opacity = 0.8 } }, function()
    text { "oicut", x = 960, y = 500, align = "center", font = ui.SANS, size = 230, fill = ui.A }
  end)
  group({ opacity = prog(lb, 1, 1.3) * fade }, function()
    text { "decode · encode · mux, in Odin", x = 960, y = 620, align = "center", font = ui.SANS, size = 44,
      fill = ui.TEXT }
  end)
  group({ opacity = prog(lb, T.WORDMARK, T.WORDMARK + 0.3) * fade }, function()
    text { "this video: an onimite script, its H.264 + AAC encoded by oicut · oicut/demo", x = 960, y = 690,
      align = "center", font = ui.MONO, size = 24, fill = ui.DIM }
  end)
end

return { name = "Outro", start = T.OUTRO, stop = T.TOTAL, render = render }
