-- Two alpha clips composited live over moving stripes: the ProRes 4444
-- avatar (transparent.mov) and a VP9-alpha WebM of it, both decoded by
-- odecs on the frame clock, each with a coloured glow.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local facts = require("facts")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

local function glow(color)
  return { filter = {
    { "blur", std = 18, input = "SourceAlpha", result = "b" },
    { "flood", color = color, opacity = 0.9, result = "c" },
    { "composite", op = "in", input = "c", input2 = "b", result = "g" },
    { "merge", "g", "SourceGraphic" },
  } }
end

local CLIPS = {
  { src = "transparent.mov", label = "ProRes 4444 · .mov", color = ui.A, x = 120, at = 0, fact = facts.PRORES },
  { src = "avatar_vp9_alpha.webm", label = "VP9 + alpha · .webm", color = ui.B, x = 1000, at = 1, fact = facts.VP9 },
}

local function render(f, lb)
  -- stripes sliding under the clips, so the alpha has something to show
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = pattern { x = lb * 60, y = 0, w = 120, h = 120,
    transform = rotate(-20), content = function()
      rect { x = 0, y = 0, w = 120, h = 120, fill = "#1a120c" }
      rect { x = 0, y = 0, w = 60, h = 120, fill = "#2a1d12" }
    end } }
  group({ opacity = 0.12 }, function()
    text { "LIVE ALPHA", x = 960 + math.sin(lb * 0.8) * 200, y = 600, align = "center", font = ui.DISPLAY, size = 300,
      fill = ui.TEXT }
  end)
  for _, c in ipairs(CLIPS) do
    if lb >= c.at then
      local s = snap(lb - c.at)
      local kick = 1 + 0.02 * pulse(lb, 8)
      group({ transform = { translate = { 0, (1 - s) * 500 }, scale = kick, origin = { c.x + 400, 520 } } }, function()
        group(glow(c.color), function()
          video_frame(f, { src = c.src, x = c.x, y = 250, w = 800, h = 450, looping = true,
            start_from = beat.beat_time(c.at) })
        end)
        ui.chip(c.x + 20, 230, c.label, c.color, ui.BG, 26)
      end)
    end
  end
  for i, b in ipairs(T.ALPHA_FACTS) do
    if lb >= b then
      local c = CLIPS[i]
      local p = snap(lb - b)
      group({ opacity = prog(lb, b, b + 0.2), transform = translate(0, (1 - p) * 30) }, function()
        text { c.fact[1] .. ", 1080p", x = c.x + 20, y = 790, font = ui.SANS, size = 34, fill = ui.TEXT }
        text { c.fact[2], x = c.x + 20, y = 880, font = ui.DISPLAY, size = 96, fill = c.color }
        text { "1 thread", x = c.x + 20, y = 915, font = ui.MONO, size = 20, fill = ui.DIM }
        text { c.fact[3], x = c.x + 300, y = 880, font = ui.DISPLAY, size = 96, fill = c.color }
        text { "8 threads", x = c.x + 300, y = 915, font = ui.MONO, size = 20, fill = ui.DIM }
      end)
    end
  end
  group({ opacity = prog(lb, T.ALPHA_FACTS[1], T.ALPHA_FACTS[1] + 0.2) }, function()
    text { facts.MOVIE_SRC, x = 960, y = 1004, align = "center", font = ui.MONO, size = 20, fill = ui.DIM }
  end)
  ui.label(lb, 1, "alpha video · decoded live, composited premultiplied")
end

return { name = "Alpha", start = T.ALPHA, stop = T.WEBP, render = render }
