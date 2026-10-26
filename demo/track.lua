-- The soundtrack: an odawg song, 13 bars, its sections named after the
-- scenes (the title has two: the intro bar and the slam). timeline.lua and
-- video.lua read it back for every cut and pop.
--
-- Why: odecs turns pixels into bits and back, so the music is textured and
-- precise with a clear pulse: West London broken beat after Bugz in the
-- Attic's "Booty La La". Its decisions: a live kit whose snare leaves the
-- backbeat every other bar, swung sixteenth hats with ghosts, a fingered
-- bass locked to the kick, jazz-funk chords moving round the circle on
-- keys. 112 BPM, below house, so the swing has room and each fact on
-- screen stays up a little longer; F minor, two chords a bar where it
-- moves (Fm9 Bb13 Ebmaj9 Abmaj9 ...), a Dbmaj9 to open on, a breakdown
-- that falls to Dbmaj9 and climbs back by a ii-V.
--
-- The hook is a marimba zig-zag up the chord tones (down a step, up two),
-- the way a codec walks a block's coefficients: under the title it plays
-- one note per chip, and it comes back in the breakdown and the outro.
-- What the picture answers to: timpani on F2 at the slam and the outro
-- (the flash), a xylophone note and its fifth under each alpha fact and
-- one under the WebP's, a pizzicato note with a bit-crushed echo as each
-- chart shrinks, the kit's kick for the pump.
--
-- Recorded instruments: Virtuosity Drums' jazz kit, Growlybass's fingered
-- Jazz Bass over a sine sub, VCSL's upright piano, and VS Chamber
-- Orchestra 2's marimba, xylophone, timpani, pizzicato and sustained strings
-- (its own SFZ files through `sources`, pinned in media/pins/vsco.pins).
-- All CC0.

local VSCO = { url = "https://raw.githubusercontent.com/sgossner/VSCO-2-CE/6dd651d55dde97fd4028699be9d4481f26917891/",
  page = "https://github.com/sgossner/VSCO-2-CE/tree/SFZ", licence = "CC0-1.0",
  credit = "VS Chamber Orchestra 2: Community Edition by Versilian Studios LLC, CC0 1.0", pins = "pins/vsco.pins" }

-- The broken beat, two bars: the snare on two and four, then late on four;
-- ghosts around it, the kick in between.
local A = { kick = "x......x..x.....", snare = "....X..o....X.o.", hat = "x.xox.xox.xox.xo", open_hat = "" }
local B = { kick = "x..x.....x.....x", snare = "..o.X......o.X..", hat = "x.xox.xox.xox...", open_hat = "..............x." }
local function groove(...)
  local bars, out = { ... }, { kick = {}, snare = {}, hat = {}, open_hat = {} }
  for i, bar in ipairs(bars) do
    for k in pairs(out) do out[k][i] = bar[k] end
  end
  return out
end
local function with(steps, extra)
  for k, v in pairs(extra) do steps[k] = v end
  return steps
end
local ALPHA, ENCODE, OUTRO = groove(A, B, A), groove(A, B, A), groove(A, B)

-- The kit's kick in each section, which a sine tuned to F1 doubles for weight.
local KICKS = { slam = { "x.........x....." }, alpha = ALPHA.kick, webp = { "x.........x.....", "x......x........" },
  encode = ENCODE.kick, outro = OUTRO.kick, tail = { "X..............." } }
-- Bars of steps as notes: each hit plays `note`, an accent accented.
local function tuned(bars, note)
  local out = {}
  for i, bar in ipairs(bars) do out[i] = bar:gsub("X", note .. "! "):gsub("x", note .. " "):gsub("%.", ". ") end
  return table.concat(out, "| ")
end

-- The hook in chord degrees, so it follows each chord: a zig-zag up two octaves.
local ZIGZAG = "3 1 5 3 7 5 8 7 10 8 12 10 14 12 . ."
-- Keys: hits off the beat, the second chord of the bar on its "e".
local COMP = "x.....x..x...x.."

return song { "score", key = "F minor", bpm = 112, seed = 112, gain_db = -12, swing = 0.16, swing_subdivision = "16n",
  sources = { vsco = VSCO },
  instruments = { {
    -- the bass: a fingered Jazz Bass over a sine sub
    deep = { layers = { { instrument = { "Sampler", set = "karoryfer/growlybass", release = 0.15 } },
                        { instrument = { "Synth", oscillator = { type = "sine" }, envelope = { attack = 0.005, decay = 0.3, sustain = 0.8, release = 0.12 } }, gain_db = -5 } } },
    -- weight under the kit's kick: a sine falling from an octave and a half above its note
    thump = { nodes = { bend = { "Decay", time = 0.04 }, amp = { "Decay", time = 0.3 },
                        out = { "Osc", wave = "sine", frequency = { by = "bend", octaves = 1.5 }, amp = "amp" } }, out = "out" },
    -- the chart pops: cello and violin sections plucking the same note
    pizz = { layers = { { instrument = { "vsco/CelloEnsPizz.sfz" } }, { instrument = { "vsco/ViolinEnsPizz.sfz" }, gain_db = -3 } } },
  } },
  sections = {
    { "title", duration = "1m", chords = "Dbmaj9" },
    { "slam", duration = "1m", chords = "Fm9" },
    { "alpha", duration = "3m", chords = "Fm9 Bb13 Ebmaj9 Abmaj9 Dbmaj9 C7" },
    { "webp", duration = "2m", chords = "Dbmaj9 Dbmaj9 Gm7b5 C7" },
    { "encode", duration = "3m", chords = "Fm9 Bb13 Ebmaj9 Abmaj9 Gm7b5 C7" },
    { "outro", duration = "2m", chords = "Dbmaj9 Eb13 Fm9 Fm9" },
    { "tail", duration = "1m", chords = "Fm9" },
  },
  returns = {
    room = { { "Reverb", decay = 0.9, pre_delay = 0.005 }, { "Filter", type = "highpass", frequency = 250 } },
    hall = { { "Reverb", decay = 2.6, pre_delay = 0.025 }, { "Filter", type = "highpass", frequency = 300 } },
    echo = { { "PingPongDelay", delay_time = "8n.", feedback = 0.3, wet = 1 }, { "Filter", type = "lowpass", frequency = 4000 } },
    -- the chart pops' shadow: quantized, then repeated on the sixteenths
    bits = { { "BitCrusher", bits = 8 }, { "FeedbackDelay", delay_time = "16n", feedback = 0.4, wet = 1 },
             { "Filter", type = "highpass", frequency = 500 } },
  },
  parts = {
    -- the jazz kick rings at 80 Hz: taken down there, the thump below carries the weight
    drums = { role = "drums", instrument = { "Sampler", set = "virtuosity/drums" }, gain_db = -3, sends = { room = -14 },
      effects = { { "Filter", type = "peaking", frequency = 80, q = 1.5, gain = -5 } }, play = {
      { "slam", velocity = 0.8, humanize = 0.005,
        steps = { kick = KICKS.slam, hat = A.hat, rim = "............x...", crash = "X..............." } },
      { "alpha", velocity = 0.85, humanize = 0.005, steps = with(ALPHA, { crash = { "X...............", "", "" } }) },
      -- the breakdown: ride and cross-stick, the kick thinned, a snare build into the encoders
      { "webp", velocity = 0.6, humanize = 0.005, steps = {
        kick = KICKS.webp, ride = "x.x.x.xxx.x.x.xx",
        rim = { "....x.......x...", "....x..........." }, snare = { "", "........o.o.oXXX" }, crash = { "X...............", "" } } },
      { "encode", velocity = 0.85, humanize = 0.005, steps = with(ENCODE, { crash = "X..............." }) },
      { "outro", velocity = 1, humanize = 0.005, steps = with(OUTRO, { crash = "X..............." }) },
      { "tail", velocity = 0.9, steps = { kick = KICKS.tail, crash = "X..............." } },
    } },
    -- felt under the kick rather than heard as a drum of its own: a texture's level
    thump = { role = "texture", instrument = { "thump" }, gain_db = -12, play = {
      { "slam", notes = tuned(KICKS.slam, "F1"), subdivision = "16n", velocity = 0.8 },
      { "alpha", notes = tuned(KICKS.alpha, "F1"), subdivision = "16n", velocity = 0.85 },
      { "encode", notes = tuned(KICKS.encode, "F1"), subdivision = "16n", velocity = 0.85 },
      { "outro", notes = tuned(KICKS.outro, "F1"), subdivision = "16n", velocity = 1 },
      { "tail", notes = tuned(KICKS.tail, "F1"), subdivision = "16n", velocity = 0.9 },
    } },
    bass = { role = "bass", instrument = { "deep" }, gain_db = -8, play = {
      { "slam", notes = "F1 - - - - - - - - - F2 . Eb2 . C2 .", subdivision = "16n", velocity = 0.8, humanize = 0.004 },
      { "alpha", subdivision = "16n", velocity = 0.8, humanize = 0.004, notes =
        "F1 - . F2 . . . Ab1 Bb1 - Bb1 . . D2 . F2 | Eb1 - . Eb2 . . Bb1 . . Ab1 - . Eb2 . . C2 | Db2 - . Ab1 . . . Db2 C2 - C2 . . E2 . G1" },
      { "webp", subdivision = "16n", velocity = 0.55, humanize = 0.004, notes =
        "Db2 - - - - - - - - - - - Ab1 - - - | G1 - - - - - - - C2 - - - E2 - G2 -" },
      { "encode", subdivision = "16n", velocity = 0.85, humanize = 0.004, notes =
        "F1 - . F2 . . . Ab1 Bb1 - Bb1 . . D2 . F2 | Eb1 - . Eb2 . . Bb1 . . Ab1 - . Eb2 . . C2 | G1 - . G2 . . . Db2 C2 - C2 . . E2 . G2" },
      { "outro", subdivision = "16n", velocity = 0.95, humanize = 0.004, notes =
        "Db2 - . Ab1 . . . Db2 Eb2 - Eb1 . . G1 . Bb1 | F1 - . F2 . . C2 . . F1 - . Ab1 . . C2" },
      { "tail", notes = "F1", subdivision = "1m", velocity = 0.75 },
    } },
    keys = { role = "comp", instrument = { "Sampler", set = "vcsl/upright_piano", release = 0.4 }, gain_db = -9, pan = -0.15,
      sends = { hall = -14 }, effects = { { "Filter", type = "lowpass", frequency = 9000, rolloff = -24 } }, play = {
      { "title", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.45 },
      { "slam", chords = { voicing = "open", rhythm = "X..............." }, octave = 3, duration = "2n.", velocity = 0.75 },
      { "alpha", chords = { voicing = "open", rhythm = COMP }, octave = 3, duration = "8n", velocity = 0.6, humanize = 0.006 },
      { "webp", chords = { voicing = "spread", rhythm = "x.......x......." }, octave = 3, duration = "2n", velocity = 0.5, humanize = 0.006 },
      { "encode", chords = { voicing = "open", rhythm = COMP }, octave = 3, duration = "8n", velocity = 0.65, humanize = 0.006 },
      { "outro", chords = { voicing = "open", rhythm = COMP }, octave = 3, duration = "8n", velocity = 0.75, humanize = 0.006 },
      { "tail", chords = { voicing = "spread", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
    } },
    marimba = { role = "melody", instrument = { "vsco/Marimba.sfz" }, gain_db = 14, pan = 0.2, sends = { hall = -14, echo = -16 }, play = {
      { "title", degrees = ZIGZAG, subdivision = "16n", octave = 4, velocity = 0.5, humanize = 0.004 },
      { "webp", degrees = ZIGZAG, subdivision = "16n", octave = 4, velocity = 0.5, humanize = 0.004,
        vary = { {}, { reverse = true } } },
      { "outro", degrees = ZIGZAG, subdivision = "16n", octave = 4, velocity = 0.55, humanize = 0.004,
        vary = { {}, { reverse = true, velocity = 0.8 } } },
    } },
    -- under each fact: the chord's root and fifth, a sixteenth apart
    pops = { role = "fx", instrument = { "vsco/Xylophone.sfz" }, gain_db = 0, sends = { hall = -12, echo = -14 }, play = {
      { "alpha", events = { { time = "1m", note = "Eb6", duration = "8n", velocity = 0.8 },
                            { time = "1:0:1", note = "Bb6", duration = "8n", velocity = 0.7 },
                            { time = "2m", note = "Db6", duration = "8n", velocity = 0.8 },
                            { time = "2:0:1", note = "Ab6", duration = "8n", velocity = 0.7 } } },
      { "webp", events = { { time = "0:3:0", note = "F6", duration = "8n", velocity = 0.75 } } },
    } },
    -- as each chart shrinks: the new chord's third, plucked
    stabs = { role = "fx", instrument = { "pizz" }, gain_db = 3, sends = { hall = -14, bits = -4 }, play = {
      { "encode", events = { { time = "0:2:0", note = "D4", duration = "8n", velocity = 0.85 },
                             { time = "1:2:0", note = "C4", duration = "8n", velocity = 0.85 },
                             { time = "2:2:0", note = "E4", duration = "8n", velocity = 0.85 } } },
    } },
    timpani = { role = "fx", instrument = { "vsco/Timpani.sfz" }, gain_db = 12, sends = { hall = -10 }, play = {
      { "slam", events = { { time = 0, note = "F2", duration = "2n", velocity = 0.95 } } },
      { "outro", events = { { time = 0, note = "F2", duration = "2n", velocity = 0.95 } } },
    } },
    -- sustained strings where the groove steps back: violas on the chord, cellos on its root
    violas = { role = "pad", instrument = { "vsco/ViolaEnsSusVib-Quiet.sfz", ampeg_attack = 0.5, ampeg_release = 1 }, gain_db = -2,
      sends = { hall = -8 }, play = {
      { "title", chords = { voicing = "close", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
      { "webp", chords = { voicing = "close", rhythm = "x.......x......." }, octave = 3, duration = "2n", velocity = 0.5 },
      { "tail", chords = { voicing = "close", rhythm = "x..............." }, octave = 3, duration = "1m", velocity = 0.5 },
    } },
    cellos = { role = "pad", instrument = { "vsco/CelloEnsSusVib-Quiet.sfz", ampeg_attack = 0.5, ampeg_release = 1 }, gain_db = 5,
      sends = { hall = -8 }, play = {
      { "title", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.5 },
      { "webp", degrees = "1 1", subdivision = "2n", octave = 2, velocity = 0.5 },
      { "tail", degrees = "1", subdivision = "1m", octave = 2, velocity = 0.5 },
    } },
    -- the violins swell over the breakdown's last bar into the encoders
    swell = { role = "fx", instrument = { "vsco/ViolinEnsSusVib.sfz", ampeg_attack = 1.8, ampeg_release = 0.4 }, gain_db = 2,
      sends = { hall = -8 }, play = {
      { "webp", events = { { time = "1m", note = "G5", duration = "1m", velocity = 0.7 },
                           { time = "1m", note = "Bb5", duration = "1m", velocity = 0.7 } } },
    } },
  },
  automation = {
    -- the piano darkens for the breakdown and opens for the encoders
    ["parts/keys/effects/Filter/frequency"] = { { "title", 2500 }, { "slam", 9000, "step" }, { "webp", 3500 },
      { "encode", 9000 }, { "tail", 3000 } },
    -- where the band is out, the dark piano comes up and the strings step back
    ["parts/keys/gain_db"] = { { "title", 10 }, { "slam", 0, "step" }, { "tail", 4, "step" } },
    ["parts/violas/gain_db"] = { { "title", -8 }, { "webp", 0, "step" }, { "tail", -9, "step" } },
    ["parts/cellos/gain_db"] = { { "title", -3 }, { "webp", 0, "step" } },
    -- the outro's hook stays in the title's octave (one up passes the marimba's top C7): lifted instead
    ["parts/marimba/gain_db"] = { { "webp", 0 }, { "outro", 2, "step" } },
  },
}
