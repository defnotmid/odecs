-- Where things happen, in beats from the start of the video (4 beats a
-- bar). The scenes animate from these numbers and track.lua puts its hits
-- on them, so picture and sound share one list.

local T = {}

-- Sections in beats; the outro has a bar of tail.
T.TITLE, T.ALPHA, T.WEBP, T.ENCODE, T.OUTRO, T.TOTAL = 0, 8, 20, 28, 40, 52
T.END = 48 -- the last hit

T.TITLE_SLAM = 4          -- the wordmark lands
T.ALPHA_FACTS = { 4, 8 }  -- alpha: the ProRes, then the VP9 numbers
T.WEBP_FACT = 3           -- webp: the decode numbers
T.SHRINKS = { 2, 6, 10 }  -- encode: one bar per chart, bars shrink on beat 3
T.WORDMARK = 4

return T
