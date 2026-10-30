-- The codecs oicut reads and writes rain in as chips on eighth notes, then
-- the wordmark slams in on bar 2 and pushes them aside.

local beat = require("beat")
local ui = require("ui")
local T = require("timeline")
local prog, snap, soft, pulse = beat.prog, beat.snap, beat.soft, beat.pulse

-- oicut README, "Packages": video, audio, images, containers.
local CHIPS = {
  { "H.264", ui.A }, { "Opus", ui.B }, { "ProRes", ui.A }, { "MP4", ui.C }, { "H.265", ui.A }, { "FLAC", ui.B },
  { "VP9", ui.A }, { "WebM", ui.C }, { "AAC", ui.B }, { "WebP", ui.TEXT }, { "AV1", ui.A }, { "MP3", ui.B },
  { "Ogg", ui.C }, { "WAV", ui.C },
}
-- where each chip lands: a loose ring around the middle, fixed at load
local SPOTS = {}
for i = 1, #CHIPS do
  local a = (i - 1) / #CHIPS * math.pi * 2 + 0.3
  SPOTS[i] = { 960 + math.cos(a) * 690 - 60, 520 + math.sin(a) * 330 }
end

local function render(f, lb)
  local slam = T.TITLE_SLAM
  rect { x = 0, y = 0, w = 1920, h = 1080, fill = radial_gradient { cx = 960, cy = 520, r = 1000,
    stops = { { 0, "#2a1a0c" }, { 0.6, "#120c08" }, { 1, ui.BG } } } }
  local push = slam <= lb and (1 - soft(lb - slam)) * 0.25 or 0
  for i, c in ipairs(CHIPS) do
    local at = T.CHIPS[i]
    if lb >= at then
      local s = snap(lb - at)
      local x, y = SPOTS[i][1], SPOTS[i][2]
      local dx, dy = (x - 960) * push, (y - 520) * push
      group({ transform = translate(dx, dy - (1 - s) * 120) }, function()
        ui.chip(x, y, c[1], ui.LINE, c[2], 30, 1 + 0.05 * pulse(lb, 8))
      end)
    end
  end
  if lb >= slam then
    local s = 1 + 0.4 * (1 - soft(lb - slam)) + 0.02 * pulse(lb, 8)
    group({ transform = { scale = s, origin = { 960, 500 } },
      shadow = { dx = 0, dy = 20, blur = 24, color = "#000000", opacity = 0.8 } }, function()
      text { "OICUT", x = 960, y = 620, align = "center", font = ui.DISPLAY, size = 380,
        fill = linear_gradient { x1 = 0, y1 = 300, x2 = 0, y2 = 620, stops = { { 0, "#fff1c9" }, { 1, ui.A } } } }
    end)
    local p = snap(lb - slam - 1)
    group({ opacity = prog(lb, slam + 1, slam + 1.2), transform = translate(0, (1 - p) * 30) }, function()
      text { "media codecs in plain Odin · no FFmpeg at runtime", x = 960, y = 730, align = "center",
        font = ui.SANS, size = 46, fill = ui.TEXT }
    end)
    if lb >= slam + 2 then
      local label = "hardware coding through Vulkan Video · native codecs as the software path"
      local w = text_width { label, font = ui.MONO, size = 22 } + 31
      ui.chip(960 - w / 2, 790, label, ui.LINE, ui.A, 22, snap(lb - slam - 2))
    end
  end
end

return { name = "Title", start = T.TITLE, stop = T.ALPHA, render = render }
