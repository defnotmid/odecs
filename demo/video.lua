-- oicut in 28 seconds: an onimite script (Odin + Lua video framework,
-- https://github.com/defnotmid/onimite) showing the codecs it decodes and
-- encodes with. Music included: the soundtrack is an odawg song
-- (track.lua), 112 BPM, and every cut and pop sits on its grid (beat.lua,
-- timeline.lua): the picture pumps on the kicks the drums really play and
-- flashes on the timpani. Numbers on screen come from oicut's docs (facts.lua).
--
--     onimite render demo/video.lua -o demo/demo.mp4

local beat = require("beat")
local ui = require("ui")
local score = require("track")
local T = require("timeline")

local SCENES = {
  require("scenes.title"),
  require("scenes.alpha"),
  require("scenes.webp"),
  require("scenes.encode"),
  (require("scenes.outro")), -- parenthesized: require also returns the file name
}

local SECTIONS = { "01 / TITLE", "02 / ALPHA VIDEO", "03 / WEBP", "04 / DECODE + ENCODE", "05 / OUTRO" }

-- Cuts that glitch for three frames. The timpani hits flash; inspect checks
-- the song really hits there.
local GLITCH_CUTS = { T.ALPHA, T.WEBP, T.ENCODE, T.ENCODE + 4, T.ENCODE + 8, T.OUTRO }
cue("impact", score.hits { part = "timpani", note = "F2" }, { hit = "score" })

local KICK = { part = "drums", note = "kick", decay = 9 }
local IMPACT = { part = "timpani", note = "F2", decay = 5 }

local function energy(f, b)
  local s = 1 + score.pulse(f, KICK) * 0.008
  local since_cut
  for _, c in ipairs(GLITCH_CUTS) do
    local fr = f.global_index - beat.beat_frame(c)
    if fr >= 0 and fr < 3 then since_cut = fr end
  end
  group({ transform = { scale = s, origin = { 960, 540 } } }, function()
    if since_cut then
      -- the picture splits in bands pushed sideways
      for i = 0, 5 do
        local dx = (beat.hash(i * 13 + since_cut * 7 + b) - 0.5) * 160 * (1 - since_cut / 3)
        group({ transform = translate(dx, 0), clip = { x = 0, y = i * 180, w = 1920, h = 180 } }, function()
          render_scenes(f)
        end)
      end
    else
      render_scenes(f)
    end
  end)
  local flash = score.pulse(f, IMPACT)
  if flash > 0.01 then rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.TEXT, opacity = flash * 0.5 } end
end

local function hud(f, b)
  if b >= T.END then return end
  local bar, q = math.floor(b / 4) + 1, math.floor(b % 4) + 1
  local section = 1
  for i, s in ipairs(SCENES) do if b >= s.start then section = i end end
  group({ opacity = 0.8 }, function()
    text { "OICUT · MEDIA CODECS", x = 60, y = 66, font = ui.MONO, size = 16, fill = ui.DIM }
    text { string.format("%d BPM   BAR %02d.%d", score.sections[score.section(f).index].bpm, bar, q), x = 1830,
      y = 66, align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 1844, y = 53, w = 14, h = 14, fill = ui.A, opacity = 0.2 + 0.8 * beat.pulse(b, 7) }
    text { SECTIONS[section], x = 1860, y = 1050, align = "right", font = ui.MONO, size = 16, fill = ui.DIM }
    rect { x = 60, y = 1062, w = 1800, h = 1, fill = ui.LINE }
    rect { x = 60, y = 1061, w = math.max(1800 * b / T.TOTAL, 1), h = 3, fill = ui.DIM }
  end)
end

video {
  width = 1920, height = 1080, fps = beat.FPS, background = ui.BG,
  audio = { { "score", fade_out = 0.5 } },
  -- the song mixes near -23 LUFS: lifted to about -14 under the limiter
  -- (audio analyze in README.md)
  master_gain_db = 9.5,
  render = function(f)
    local b = beat.gbeat(f)
    rect { x = 0, y = 0, w = 1920, h = 1080, fill = ui.BG }
    energy(f, b)
    hud(f, b)
  end,
}

for _, s in ipairs(SCENES) do
  local start, render = s.start, s.render
  scene { s.name, duration = { frames = beat.beat_frame(s.stop) - beat.beat_frame(start) }, render = function(f)
    render(f, beat.gbeat(f) - start)
  end }
end
