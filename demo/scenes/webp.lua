-- bryce.webp, the largest image in libwebp's test corpus (11158x2156
-- lossy), decoded by oicut and panned across the frame.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft = beat.prog, beat.snap, beat.soft

local H = 1080
local W = H * 11158 / 2156

local function render(f, lb)
  local span = T.ENCODE - T.WEBP
  local t = prog(lb, 0, span)
  local x = -(W - 1920) * (t * t * (3 - 2 * t))
  local zoom = 1.12 - 0.12 * soft(lb)
  group({ transform = { scale = zoom, origin = { 960, 540 } } }, function()
    image { src = "bryce.webp", x = x, y = 0, w = W, h = H }
  end)
  rect { x = 0, y = 640, w = 1920, h = 440, fill = linear_gradient { x1 = 0, y1 = 640, x2 = 0, y2 = 1080,
    stops = { { 0, "#0b080600" }, { 1, "#0b0806f0" } } } }
  ui.label(lb, 2, "WebP · lossy, lossless, alpha, animation")
  local p = snap(lb - 0.5)
  group({ opacity = prog(lb, 0.5, 0.7), transform = translate((1 - p) * -60, 0) }, function()
    text { "bryce.webp", x = 120, y = 820, font = ui.DISPLAY, size = 110, fill = ui.TEXT }
    text { facts.WEBP_SIZE .. " lossy, from libwebp's test corpus", x = 124, y = 868, font = ui.MONO, size = 26,
      fill = ui.TEXT }
  end)
  local b = T.WEBP_FACT
  local q = snap(lb - b)
  group({ opacity = prog(lb, b, b + 0.2), transform = translate(0, (1 - q) * 30) }, function()
    text { facts.WEBP_OURS, x = 1800, y = 820, align = "right", font = ui.DISPLAY, size = 130, fill = ui.A }
    text { "to decode on one core · libwebp: " .. facts.WEBP_LIBWEBP, x = 1800, y = 866, align = "right",
      font = ui.MONO, size = 26, fill = ui.TEXT }
    text { string.format("all %d corpus files decode RGBA-identical to dwebp", facts.WEBP_CORPUS), x = 1800,
      y = 912, align = "right", font = ui.MONO, size = 26, fill = ui.TEXT }
  end)
  group({ opacity = prog(lb, b, b + 0.2) }, function()
    text { facts.WEBP_SRC, x = 960, y = 1004, align = "center", font = ui.MONO, size = 20, fill = ui.DIM }
  end)
end

return { name = "WebP", start = T.WEBP, stop = T.ENCODE, render = render }
