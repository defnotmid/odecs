-- Three charts, a bar each: Vulkan Video decoding and encoding, where
-- the bars shrink on beat 3 from one picture at a time to three in
-- flight, and the pooled native H.264 encoder next to x264.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft, pulse, expo_out = beat.prog, beat.snap, beat.soft, beat.pulse, beat.expo_out

local X0, BAR_W = 640, 1000

local function chart(c, lb, shrink)
  local p = snap(lb)
  group({ opacity = prog(lb, 0, 0.15), transform = translate(0, (1 - p) * 40) }, function()
    text { c.title, x = 120, y = 290, font = ui.DISPLAY, size = 110, fill = ui.TEXT }
    text { c.unit .. (c.fps and " · higher is faster" or " · lower is faster"), x = 124, y = 334, font = ui.MONO,
      size = 24, fill = ui.DIM }
  end)
  local max = 0
  for _, r in ipairs(c.rows) do max = math.max(max, r[2]) end
  local k = c.fps and 0 or expo_out(prog(lb, shrink, shrink + 0.6))
  for i, r in ipairs(c.rows) do
    local y = 420 + (i - 1) * 150
    local grow = expo_out(prog(lb, 0.25 * i, 0.25 * i + 0.6))
    local v = c.fps and r[2] or (r[2] + (r[3] - r[2]) * k)
    local w = BAR_W * v / max * grow
    text { r[1], x = 120, y = y + 52, font = ui.SANS, size = 36, fill = ui.TEXT }
    if w > 0 then
      local color = (c.fps and i == 2) and ui.DIM or (k > 0.5 and ui.B or ui.A)
      rect { x = X0, y = y, w = w, h = 80, rx = 12, fill = color }
      if not c.fps then
        rect { x = X0 + BAR_W * r[3] / max, y = y - 8, w = 3, h = 96, fill = ui.TEXT, opacity = 0.4 * (1 - k) * grow }
      end
    end
    group({ opacity = grow }, function()
      text { c.fps and string.format("%d", r[2]) or string.format("%.2f", v), x = X0 + w + 20, y = y + 62,
        font = ui.DISPLAY, size = 76, fill = ui.TEXT }
    end)
  end
  if not c.fps then
    local label = k > 0.5 and c.to or c.from
    ui.chip(120, 870, label, k > 0.5 and ui.B or ui.LINE, k > 0.5 and ui.BG or ui.TEXT, 26,
      1 + 0.15 * (1 - soft(lb - shrink)) * (lb >= shrink and 1 or 0))
  end
  text { c.src, x = 960, y = 1004, align = "center", font = ui.MONO, size = 20, fill = ui.DIM }
end

local function render(f, lb)
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
  local i = math.min(math.floor(lb / 4) + 1, #facts.CHARTS)
  local local_b = lb - (i - 1) * 4
  chart(facts.CHARTS[i], local_b, T.SHRINKS[i] - (i - 1) * 4)
  ui.label(local_b, 2 + i, i == 3 and "native encoding on the work pool" or "Vulkan Video · H.264 · H.265 · AV1")
end

return { name = "Encode", start = T.ENCODE, stop = T.OUTRO, render = render }
