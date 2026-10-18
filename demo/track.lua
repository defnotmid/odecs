-- The soundtrack: an odawg song, 120 BPM broken beat in E minor (Em C G D,
-- a chord a bar), 13 bars, its sections named after the scenes (the title
-- has two: the intro bar and the slam). House's bass, stabs, pad and pluck
-- arpeggio over a broken beat (the kick on 1, the "and" of 2 and the "and"
-- of 3, claps on 2 and 4, sixteenth hats); a breakdown over the WebP
-- panorama, an ambient tail. The transitions make the risers and the
-- impacts on the slam and the outro; the parts below add what the picture
-- answers to: the title's chips, the facts' pops, the charts' shrinking
-- bars, a crash on each scene's and each chart's downbeat. timeline.lua
-- reads them back.

local MACHINE = { "DrumMachine", machine = "909" }
local BREAK = { kick = "x.....x...x.....", clap = "....x.......x...", hat = "xxXxxxXxxxXxxxXx" }

return song { "score", key = "E minor", bpm = 120, seed = 120,
  sections = {
    { "title", duration = "1m", style = "house", energy = 0.3, chords = "Em" },
    { "slam", duration = "1m", energy = 0.5, chords = "C", transition = "impact" },
    { "alpha", duration = "3m", energy = 0.8, chords = "G D Em", transition = "none" },
    { "webp", duration = "2m", energy = 0.35, chords = "C G", transition = "none" },
    { "encode", duration = "3m", energy = 0.8, chords = "D Em C", transition = "riser" },
    { "outro", duration = "2m", energy = 1, chords = "G D", transition = "impact" },
    { "tail", duration = "1m", style = "ambient", energy = 0.3, chords = "Em", transition = "cut" },
  },
  parts = {
    -- the broken beat: hats alone in the title, open hats from the encoders on
    drums = { gain_db = 1,
      play = { { "title", steps = { hat = BREAK.hat } },
               { "slam", steps = { kick = BREAK.kick, hat = BREAK.hat } },
               { "alpha", steps = BREAK },
               { "webp", steps = { hat = "x.x.x.x.x.x.x.x." }, velocity = 0.7 },
               { "encode..outro", steps = { kick = BREAK.kick, clap = BREAK.clap, hat = BREAK.hat,
                 open_hat = "..x...x...x...x." } },
               { "tail", steps = { kick = "X..............." } } } },
    pad = { gain_db = -16 },
    arp = { play = { { "alpha@2m..", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, velocity = 0.8 },
                     { "webp", arpeggio = { pattern = "upDown", interval = "16n", octaves = 2 }, velocity = 0.8 } } },
    -- a crash on the alpha's and the WebP's downbeats, on each chart's, on
    -- the wordmark and on the last kick
    crash = { instrument = MACHINE, gain_db = -2,
      play = { { "alpha", steps = { crash = { "X...............", "", "" } } },
               { "webp", steps = { crash = { "X...............", "" } } },
               { "encode", steps = { crash = "X..............." } },
               { "outro", steps = { crash = { "", "X..............." } } },
               { "tail", steps = { crash = "X..............." } } } },
    -- a stutter on the title's first beat and on each chart's shrink
    glitch = { instrument = "glitch", gain_db = -10,
      play = { { "title", steps = "x...............", note = "1", duration = "4n" },
               { "encode", steps = "........x.......", note = "1", duration = "4n" } } },
    -- the pops: a run under the title's chips, the alpha's two facts (a
    -- blip and its fifth each), the WebP's
    blips = { instrument = "blip", gain_db = -2, octave = 5,
      play = { { "title", degrees = "1 2 3 4 5 6 7 8", subdivision = "8n", velocity = 0.5 },
               { "alpha@1m..", degrees = "1 5 . . . . . . . . . . . . . . | 1 5 . . . . . . . . . . . . . .",
                 subdivision = "16n", octave = 6 },
               { "webp", degrees = ". . . 1 . . . .", subdivision = "4n", octave = 6 } } },
  },
}
