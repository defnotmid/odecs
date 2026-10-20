# Movie files: RGBA and PCM to and from MP4 and WebM

`movie` is a thin layer over [`media`](../media/README.md) and
the [MP4](../mp4/README.md) and [WebM](../webm/README.md)
containers. It takes RGBA8 frames and interleaved `f32` PCM and writes an MP4
with H.264/H.265 and AAC-LC tracks, or a VP9 WebM. It also reads such files
(and many others) back as RGBA8 frames and PCM. Everything is native Odin.
`Automatic` decodes in hardware when the machine admits the stream:
VideoToolbox on macOS (H.264 and HEVC), Vulkan Video on Linux. Encoding
likewise uses VideoToolbox on macOS and Vulkan Video on Linux, and the
native codecs elsewhere (and for alpha and VP9).

## Writing

```odin
import movie "../movie"

config := movie.default_writer_config(1920, 1080, 30000, 1001) // qp 23, faststart
config.codec = .H264                 // or .H265
config.sample_rate, config.channels = 48000, 2
w: movie.Writer
err := movie.create(&w, "out.mp4", config)   // or create_stream
err = movie.write_audio(&w, pcm)     // any amount, any time
for frame in frames do err = movie.write_frame(&w, frame.rgba, frame.width * 4)
err = movie.finish(&w)
movie.destroy(&w)
```

- **Pixels:** RGBA8, sRGB, straight alpha by default. `Alpha.Premultiplied`
  and `Alpha.Opaque` are also available. Straight and premultiplied pixels
  are composited over `background` (default black); video carries no alpha
  unless `transparency` is set (below).
- **Colour:**
  - Frames convert to BT.709 limited-range 4:2:0. Chroma is the average of
    each 2x2 block.
  - The colour description (primaries/transfer/matrix 1/1/1, limited range)
    goes in both the SPS VUI and the `colr` box.
  - `write_i420` (or `write_nv12`, interleaved chroma as Vulkan Video
    stores it, uploaded row by row) accepts frames already in that format, for example from a
    GPU conversion.
- **Size:** even width and height, 16..8192. Anything else is
  `Invalid_Config`.
- **Frame rate:** `fps_num/fps_den` is exact; 30000/1001 is stored as 1001
  ticks of a 30000 Hz track. The timescale is the numerator doubled up to at
  least 10 kHz (30/1 becomes 15360). Frames are constant-rate.
- **Quality:** `qp` is a constant quantizer, 1..51, default 23. `gop` is the
  keyframe interval in frames; 0 means about one second. Hardware and native
  encoders produce different bitstreams at the same QP, so equal QP does not
  mean equal size or quality:
  - **Native H.264** is Constrained Baseline: CAVLC, I/P.
  - **Vulkan H.264** is High: CABAC, I/P.
  - **H.265** is Main.
- **Encoder selection:** `preference` chooses Automatic, Native or
  Require_Hardware. `video_backend` reports what was selected. The optional
  `native_options` (worker pool, slices/tiles) and `gpu_context` pass through
  to the providers.
- **Audio:**
  - Interleaved `f32` PCM at a standard AAC rate (7350..96000); any other
    rate is `Unsupported`. Use 1..8 channels in AAC canonical order: C, L, R,
    then surrounds, then LFE. Stereo is L, R.
  - Samples are clamped to [-1, 1], and NaN becomes 0.
  - The final partial frame is zero-padded, and the edit list trims priming
    and padding to the exact input length.
  - Encoded audio is queued and interleaved with video in runs of about half
    a second. Supply audio before or alongside the video; audio written after
    the last frame is stored after the video, which is valid but not
    interleaved.
  - **Audio-only `.m4a`:** `default_audio_writer_config(sample_rate, channels)`
    (or `width == 0 && height == 0` with `sample_rate > 0 && channels > 0`)
    writes an audio-only AAC-LC `.m4a` (`ftyp` major brand `M4A `).
- **VP9 / WebM:** `codec = .VP9` writes WebM with the native VP9 encoder
  (`base_q_idx = 5 * qp`, video only: audio is `Unsupported`). With
  `transparency = .Straight` the alpha travels as a second VP9 stream in
  BlockAdditional 1, which Chrome, Firefox and Edge composite. Files are
  still several times larger than libvpx's (see `vp9/encoder`).
- **Transparency:** `transparency = .Premultiplied` or `.Straight` keeps alpha
  as an H.265 auxiliary alpha layer (native encoder; Annex F, laid out as
  Apple's VideoToolbox encoder writes it), which Safari, QuickTime and
  AVFoundation play as transparent video. `alpha` still says how the RGBA
  input relates to its alpha; `write_i420` and `write_nv12` take an alpha
  plane beside colour already converted.
  - **Premultiplied** (`alpha_channel_use_idc` 1, Apple's default) is the
    picture over black: smallest, but 4:2:0 shares chroma between thin
    strokes and their transparent neighbours (about 33 dB on the test clip
    at any QP).
  - **Straight** (`alpha_channel_use_idc` 0, also what VP9/WebM needs)
    weights each 2x2 chroma average by alpha and smooths colour where
    alpha is low toward its surroundings (a push-pull pyramid), within the
    values that look identical once multiplied by alpha. Better quality per
    bit on edges and text (40 dB at about the size premultiplied needs for
    33).
  - The reader honours the SEI: premultiplied files are not multiplied
    twice, and `Frame.planar.alpha_premultiplied` reports the form.
  - Checked with `tests/movie_alpha_write.odin` (round trip, both forms),
    FFmpeg's and VideoToolbox's decoders (same pictures within 0.3 dB).
- **Output:** `faststart` (on by default) puts `moov` first for progressive
  playback. `create_stream` writes to any stream with `Write_At`, such as an
  `mp4.Memory_Stream` for in-memory segments.

## Reading

```odin
r: movie.Reader
err := movie.open_reader(&r, "in.mov", {preference = .Native}) // or open_reader_stream
// r.video: codec, width, height, frame_count, fps_num/den, duration, rotation,
//          color, has_alpha, bit_depth, chroma, decodable
// r.audio: codec, present, sample_rate, channels, samples
for {
    f, e := movie.next_frame(&r)     // sequential playback
    if e == .End_Of_Stream do break
    // f.rgba (borrowed until the next call), f.pts, f.time, f.index
}
f, e := movie.frame_at(&r, 12.34)   // frame on screen at 12.34 s
keys := movie.keyframe_times(&r) // where decoding can restart, ascending
n, e2 := movie.read_audio(&r, pcm)  // interleaved f32 from the audio position
movie.seek_audio(&r, 12.34)
movie.close_reader(&r)
```

- **Inputs:** MP4, `.m4a` and QuickTime `.mov` (including fragmented
  `moof`/`traf`; H.264, H.265, ProRes, AV1; AAC-LC, ALAC, FLAC, MP3, Opus or
  PCM audio) and WebM/Matroska `.webm`/`.mkv` (VP9, H.264, H.265, AV1; AAC-LC,
  FLAC, MP3, Opus (every mode, surround included; see [`opus`](../opus/README.md)) or
  PCM audio; Vorbis is reported in `Audio_Info.codec` but not decoded), and
  audio-only WAV, Ogg Opus (`.opus`, `.ogg`), native `.flac`
  (which seeks with its seek table and bisection, never reading the whole
  file) and `.mp3` (frames indexed at open, LAME gapless trimming; seeks
  pre-roll 13 frames so the bit reservoir is complete and the output exact).
  Matroska `DiscardPadding` trims the end.
  The container is recognised from the first bytes, not the file name.
  Matroska block timestamps are rounded (usually to 1 ms), so audio
  packets are placed by their frame sizes from the first timestamp, and
  `CodecDelay` priming is trimmed; Matroska has no reorder flag, so H.264
  from `.mkv` always decodes with reordering allowed.
- **Frames:** RGBA8 with tight rows. Alpha is 255 unless `has_alpha` (ProRes
  4444 with alpha, VP9 with an alpha stream, HEVC with an alpha layer). Alpha is then straight by
  default, or premultiplied with `Reader_Config.premultiplied_alpha`. It is
  scaled to 8 bits exactly at 0 and full scale, in the same Q16 pass as the
  colour conversion. VP9 sRGB (G, B, R planes) converts directly. With a
  pool in `native_options`, decoding and conversion (in bands of 64 rows)
  both run on it.
- **Planar output:** with `Reader_Config.format = .Planar`, frames carry
  `Frame.planar` instead of RGBA: tight Y', Cb, Cr planes (G, B, R when
  `color.matrix_coeffs` is 0) at the decoder's subsampling, a luma-sized
  straight alpha plane when the video has one, and the bit depth, storage
  (bytes at 8 bits, little-endian `u16` above, LSB-aligned), resolved colour
  description and chroma location. The planes are copied once per frame in
  bands on the pool (8-bit content in Vulkan Video's 16-bit output narrows
  to bytes), with no conversion. `planar_to_rgba` is the reader's own
  conversion, a reference for a shader; `tests/movie_planar.odin` checks
  that it reproduces the RGBA output exactly across 4:2:0/4:2:2/4:4:4,
  alpha, G/B/R, 8 to 12 bits, HDR and Vulkan decode. Planar is smaller than
  RGBA's 4 bytes/pixel for 4:2:0 (1.5 at 8 bits, 3 at 10), equal for
  10-bit 4:2:2 and larger for 4:4:4 at 10/12 bits (6, or 8 with alpha). HDR
  sources need their transfer handled by the consumer; the RGBA path tone
  maps them.
- **Colour:**
  - The conversion follows the file's `colr`. Fields it leaves unspecified,
    and the range that a QuickTime `nclc` box cannot carry, come from the
    SPS VUI. Without either, it applies the common player rule: BT.601 up to
    576 lines, BT.709 above.
  - Full-range and 10-bit sources convert as signalled.
  - HDR (PQ, HLG) and BT.2020 sources are tone- and gamut-mapped to SDR
    BT.709 (`hdr.odin`): the transfer's EOTF to light relative to SDR white
    (203 nits, BT.2408; HLG with BT.2100's luminance-based OOTF for a
    1000-nit display), BT.2020 to BT.709 primaries with clipping, the BT.2390
    EETF on max(R, G, B) from a 1000-nit peak to SDR white (hue kept), and
    the BT.1886 inverse (gamma 2.4). The curves are table loads indexed by
    the float's exponent and mantissa. Against FFmpeg zscale's linear light
    through the same curve, PQ is within one 8-bit step for 99.9% of values
    (4:4:4 source). zscale's HLG applies the OOTF per channel, which BT.2100
    does not, so HLG is checked against worked BT.2100 values instead.
    Mastering metadata is not read; 1000 nits is assumed.
  - Cost: about 11 ms per 1080p frame and 42 ms per 4K frame on one thread
    (the SDR integer path takes 0.8 and 3.2 ms), split into 64-row bands on
    the pool.
  - Chroma is replicated (nearest neighbour). FFmpeg's 10-bit path
    interpolates chroma, so saturated sharp edges differ slightly.
- **Presented frames** run from the frame on screen at time zero to the
  last frame that starts before the edit list's end. `frame_count` and
  `Frame.index` count only these. Pre-roll and tail frames that the edit
  hides are never returned.
  - A first frame that straddles zero (negative `time`) is presented,
    because it is on screen at zero. FFmpeg drops it and re-bases the next
    frame to 0; the reader keeps the edit list's exact times.
- **`next_frame`** returns the presented frames in order and continues after
  a `frame_at`.
- **`frame_at(seconds)`** returns the frame on screen at that instant: the
  greatest `pts` at or before it, rounded to the nearest tick, clamped to
  the first and last presented frames.
  - Moving forward within the decoded GOP continues decoding, and
    intermediate frames are not converted.
  - Otherwise it restarts at the keyframe at or before the target. ProRes
    is intra-only, so it decodes just the target. VP9 restarts at the
    previous keyframe from the block index built at open. Leading pictures
    of an open GOP are skipped.
  - Requesting the current frame again returns it without work.
- **`keyframe_times`** lists the presented times where decoding can
  restart: the first presented frame, then each presented keyframe (every
  frame for ProRes). `frame_at` one of them decodes no earlier frame, and
  `next_frame` from there returns the span up to the next one, so a player
  can go backwards a span at a time. The slice is built on the first call
  and borrowed until `close_reader`.
- **`Video_Info.decodable`** is probed at open (native first, the hardware
  decoders only when native refuses) without opening a session. A file
  whose video no decoder admits still opens, so its audio stays readable;
  `error_detail` says why, and `next_frame`/`frame_at` return
  `.Unsupported`.
- **Timestamps:** pictures leave the decoder in presentation order, and each
  takes the smallest outstanding `pts`. A stream without composition offsets
  sets the decoder's `no_reordering`, so frames come out as soon as they are
  decoded.
- **Audio:**
  - The first AAC-LC or QuickTime PCM track is decoded (8-bit unsigned;
    16/24/32-bit integer and 32/64-bit float, either endianness). HE-AAC is
    refused.
  - PCM index zero is movie time zero: priming and padding are trimmed by the
    edit list, and a delayed track starts with silence.
  - `seek_audio` restarts one access unit early to rebuild the MDCT overlap,
    and matches sequential decoding.
- **Hardware seeks:** when Vulkan wins admission, the reader moves to a
  reader-owned shared device. Restarts then reopen sessions on it instead of
  creating a device each time.

## What the caller handles

- **Odd sizes:** 4:2:0 cannot represent them, so round the canvas up to even
  before rendering (fframes does the same) or crop/pad yourself.
- **Alpha when writing:** composited over `background` unless
  `transparency` keeps it (see Writing). Reading ProRes 4444, VP9 or HEVC
  with alpha returns it.
- **Rotation:** frames are returned unrotated, as stored. Apply
  `Video_Info.rotation` (clockwise degrees) yourself.
- **Variable frame rate:** reading is pts-based and handles VFR. Writing is
  constant-rate.
- **Sample-rate conversion and channel mixing:** decoded PCM keeps the
  file's rate and channel layout. Resample and mix it (for example with
  fframes' Kaiser-sinc mixer) before writing at one standard rate.
- **Seek cost:** a backward or far seek restarts at the keyframe. Short GOPs
  make random access cheaper, at a size cost. For scrubbing small frames,
  the native decoder restarts faster than Vulkan Video; see below.
- **Parallel segment encoding:** encode GOP-aligned segments with separate
  Writers (or `mp4.Writer`s) into `Memory_Stream`s. Then concatenate their
  packets with `mp4.Reader` and `mp4.Writer`, continuing the timestamps. The
  parameter sets must be identical, so use the same configuration and
  backend for every segment.
- **Containers and codecs:** writing is MP4 with H.264/H.265 and AAC-LC.
  Reading adds ProRes and PCM in `.mov`, FLAC and MP3 in MP4, VP9, H.264,
  H.265, AAC, FLAC, MP3, Opus and PCM in WebM/MKV, AV1 in MP4 and WebM/MKV
  (Vulkan Video only), Ogg Opus, `.wav`, `.flac` and `.mp3`. VP8 and
  Vorbis are not decoded.
- **VP9 seek cost:** a far seek decodes from the previous keyframe. At
  1080p, a 60-frame GOP and one thread, that is up to about 0.5 s; encode
  overlays with a short GOP (`-g 30` or less) when they will be scrubbed.

## Performance

Reading alpha video at 1920x1080 (`tests/movie_alpha.odin`: frames through
RGBA including conversion, file input; seeks are random `frame_at` calls;
other load on the machine, 8-thread figures are best of several runs):

| Clip | 1 thread | 8 threads | `frame_at` median (1 / 8 threads) |
| --- | --- | --- | --- |
| ProRes 4444 + alpha | 88 fps | 322 fps | 19 / 8 ms |
| ProRes 422 HQ | 207 fps | 444 fps | 6.6 / 2.3 ms |
| VP9 + alpha stream, GOP 30 | 72 fps | 183 fps | 271 / 141 ms |
| VP9, GOP 60, two-pass | 150 fps | 293 fps | 253 / 118 ms |
| fframes `transparent.mov` (640x360 4444) | 684 fps | 3142 fps | 1.8 / 0.4 ms |

The timing harness is `tests/movie_timing.odin`, pinned to one core (AMD Ryzen 9 9900X3D 12-Core Processor,
`-o:speed -microarch:native`), with resident input and the median of 7.

| 1920x1080 | ms/frame |
| --- | --- |
| `rgba_to_i420`, straight alpha | 0.385 |
| `rgba_to_i420`, opaque | 0.310 |
| `yuv_to_rgba`, 8-bit 4:2:0 | 0.230 |
| `next_frame` over raw native decode of the same samples | +0.4 and −0.1 in two runs, within decode noise (4.1–6.7) |

- **Encode conversion:** it is about 1% of a native H.264 1080p encode frame
  (26 fps, 38 ms).
- **SoA restructure:** conversion first ran as one 2x2-block loop. Splitting
  it into a unit-stride RGBA→(luma, planar R/G/B) pass and a separate chroma
  pass made the output bit-identical and cut straight-alpha time 6.52 → 0.385
  ms. Harness instructions went 48.1 G → 3.9 G and cycles 11.2 G → 1.0 G.
- **Measured at 640x360 on this host's AMD GPU:**
  - Sequential playback: 159 fps with Vulkan H.264, 240 fps native.
  - Backward seeks: 4.8 ms native, 40 ms Vulkan H.264 and 27 ms Vulkan
    H.265, on the reader's shared device. Without it, each restart took
    149 ms.

## Validation

```sh
odin test movie -o:speed
bash tests/mp4_check.sh /tmp/odecs-mp4
odin run tools/mp4_smoke -o:speed -- /tmp/smoke.mp4 --codec h264
```

- **Unit tests:** BT.709 code values, alpha modes and flat-colour inversion
  (within ±2). H.264 and H.265 writer→reader round trips check:
  - PSNR above 32 dB at QP 18
  - exact frame indices for 20 random lookups
  - the exact audio sample count, audio SNR, and seek consistency
- **`tests/mp4_check.sh`:**
  - It writes six configurations, including 30000/1001, no-faststart and
    no-audio. FFmpeg must decode each without messages, and our decode must
    match FFmpeg's frame by frame. Each frame must match its own index
    better than its neighbours.
  - It reads x264 B-frame, open-GOP, x265 B-frame, Main10, QuickTime MOV
    (including full range signalled only by the VUI), cropped 646x358 at
    24000/1001, edit-list-trimmed and stream-copy-cut files (hidden pre-roll,
    a frame straddling zero), fragmented MP4/M4A, ALAC `.m4a` (16-bit and
    24-bit 96 kHz), and Opus in MP4. The checks
    are frame alignment, the oracle's first frame time, the exact audio
    sample count, and SNR against FFmpeg's decode.
- **Manual browser check:** headless Chromium 152 played the H.264 output
  (native Baseline and Vulkan High) with the right size and duration and
  with audio. Flat colours came back as BT.709, red and green exact. Blue
  was within 9: Chromium's software path rounds BT.709's blue coefficient,
  and FFmpeg decodes the same file within ±2. That Chromium build has no
  HEVC decoder, so H.265 MP4 depends on the platform (hardware HEVC in
  Chrome, Safari). Firefox and QuickTime were not available on the test
  host.
