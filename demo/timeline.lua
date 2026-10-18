-- Where things happen, in beats from the start of the video (4 beats a
-- bar), read from the song (track.lua): its sections are the scenes, its
-- blips and stutters the pops the picture answers to, so picture and sound
-- share one list.

local score = require("track")

local T = {}

-- The beat at a position in the song's grammar ("alpha", "outro@1m").
local function at(pos) return score.beat(score.time(pos)) end
-- The song's hits of `part` in section `section`, in beats into it.
local function hits(part, section)
  local out, start = {}, at(section)
  for i, t in ipairs(score.hits { part = part, range = section }) do out[i] = score.beat(t) - start end
  return out
end

-- Sections in beats; the outro has a bar of tail.
T.TITLE, T.ALPHA, T.WEBP, T.ENCODE, T.OUTRO = at("title"), at("alpha"), at("webp"), at("encode"), at("outro")
T.END = at("tail") -- the last hit
T.TOTAL = score.beat(score.duration)

T.TITLE_SLAM = at("slam") - T.TITLE           -- the wordmark lands
do
  local pops = hits("blips", "alpha")         -- alpha: the ProRes, then the VP9 numbers (a blip and its fifth each)
  T.ALPHA_FACTS = { pops[1], pops[3] }
end
T.WEBP_FACT = hits("blips", "webp")[1]        -- webp: the decode numbers
T.SHRINKS = hits("glitch", "encode")          -- encode: one bar per chart, bars shrink on beat 3
T.WORDMARK = at("outro@1m") - T.OUTRO

return T
