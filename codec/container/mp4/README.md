# MP4 (ISO base media file format)

Native Odin muxing and demuxing of H.264, H.265 and AAC in MP4/MOV files,
and reading of QuickTime ProRes and PCM. The
package imports only Odin `core`. Codec configuration records are built from
the parameter sets in the stream. Sample bytes pass through unchanged, apart
from Annex-B/length-prefix framing. For RGBA frames and PCM in or out, use
[`codec/movie`](../../movie/README.md), which drives this package and
`codec/media`.

## Writing

```odin
import mp4 "../codec/container/mp4"

w: mp4.Writer
tracks := []mp4.Track_Config{
    {codec = .H264, timescale = 15360, width = 1920, height = 1080,
     color = mp4.BT709_LIMITED, default_duration = 512},
    {codec = .AAC, timescale = 48000, sample_rate = 48000, channels = 2,
     audio_specific_config = asc, default_duration = 1024},
}
err := mp4.create(&w, "out.mp4", tracks, {faststart = true})
err = mp4.write_video_packet(&w, 0, annex_b_au, pts, dts, keyframe)
err = mp4.write_audio_packet(&w, 1, aac_au, pts)  // raw AU; ADTS is stripped
err = mp4.set_track_end(&w, 1, input_samples)     // trim AAC padding
err = mp4.finish(&w)
mp4.destroy(&w)
```

- **Timestamps** are track-timescale ticks on the movie timeline, where zero
  is the start of presentation. `dts` must increase strictly per track.
- **Edit lists** are derived from the timestamps:
  - Samples with negative `pts` are hidden: AAC priming at `-1024`, or
    B-frame pre-roll when `dts` starts below zero.
  - A track whose first `pts` is positive starts after an empty edit.
  - `set_track_end` ends the presentation early, for example to trim AAC
    padding to the original input length.
- **Movie timescale:** by default it is the first audio track's sample rate,
  so audio edits are sample-exact. Otherwise it is the first track's
  timescale. `Options.movie_timescale` overrides it.
- **Sample tables:** `stts` and `ctts` are run-length coded, with `ctts`
  version 1 when any `pts < dts`. `stss` is written only when some sample is
  not a sync sample.
- **Chunks** are runs of consecutive samples of one track, recorded in
  `stsc`. Chunk offsets use `stco`, or `co64` once any offset passes 4 GiB
  (`force_co64` forces it).
- **Faststart:** `mdat` sits behind a `wide` placeholder, so it widens to
  64-bit sizes in place. With `faststart`, `finish` moves the media data
  forward once, in 4 MiB blocks, and writes `moov` before it.
- **Parameter sets:** SPS/PPS (and VPS) NAL units move into `avcC`/`hvcC` and
  are not repeated in samples, as `avc1`/`hvc1` require. Access unit
  delimiters are dropped. A different set under an existing identifier
  returns `Unsupported`; write such a stream to a new file.
- **Sync samples:** a sample is marked sync when the caller says so or when
  it contains an IDR/IRAP picture.
- **Sample entries:** `avc1` + `avcC` (with the High-profile chroma and
  bit-depth fields), `hvc1` + `hvcC`, and `mp4a` + `esds`. `colr` nclx is
  written when `Track_Config.color` is set, and `pasp` is 1:1.
- **Incremental access units:** `begin_sample`, `add_nal`/`add_annex_b`/
  `add_bytes`, then `end_sample`. A sample holding only parameter sets is
  dropped. `starts_access_unit` and `is_picture_nal` group an encoder's NAL
  stream into samples.
- **No reordering:** packets are written in call order. Interleave tracks by
  time yourself; `codec/movie` does this. Independently encoded segments can
  be concatenated at packet level when their parameter sets are identical:
  write each segment's packets in order with continuing timestamps.
- **Output:** a path, or any `io.Stream` with `Write_At` (plus `Read_At` for
  faststart). `Memory_Stream` is a growable in-memory stream.

## Reading

```odin
r: mp4.Reader
err := mp4.open(&r, "in.mp4")           // or open_stream
for t, i in r.tracks { /* kind, codec, timescale, width/height, config, ... */ }
p, e := mp4.next_packet(&r)             // all tracks, decode-time order
p, e = mp4.read_sample(&r, track, index)
k := mp4.keyframe_at(&r.tracks[i], pts) // decode from k forward
s := mp4.sample_at(&r.tracks[i], pts)   // sample shown at pts
mp4.close(&r)
```

- **Timestamps:** every `Sample` carries `offset`, `size`, `dts`, `pts`,
  `duration` and `sync`. Times are track ticks with the edit list already
  applied: `pts` 0 is the first presented instant, and samples an edit hides
  have negative `pts`.
- **Edit lists:** the reader applies an optional empty edit plus one normal
  edit at rate 1, keeping the delay and the presented duration. Longer lists
  keep their first normal edit and set `Edit.complex`.
- **Presentation order:** `presentation` lists sample indices sorted by
  `pts`, in O(n log n) even for adversarial `ctts`. `no_reordering` is set when `pts == dts` throughout. In that case
  pass `Config.no_reordering` to the H.264 decoder for immediate output.
- **Seeking:** `keyframe_at` returns the last sync sample at or before the
  target. Decode forward from it, and skip samples whose `pts` precedes the
  keyframe's: those are leading pictures of an open GOP.
- **Track metadata:**
  - `rotation` holds the clockwise degrees from the `tkhd` matrix. A phone
    portrait clip reads 90, where ffprobe shows −90.
  - `color` comes from `colr` nclx/nclc. `color_range_signalled` is false
    for nclc, which has no range flag; take the range from the VUI then.
  - `config` holds the `avcC`/`hvcC` record, and `audio_specific_config` the
    AAC ASC.
- **QuickTime:** ProRes sample entries (`apco`, `apcs`, `apcn`, `apch`,
  `ap4h`, `ap4x`) read as codec `ProRes`, one frame per sample, with `colr`
  and `fiel` (`interlaced`). Uncompressed audio (`raw `, `twos`, `sowt`,
  `in24`, `in32`, `fl32`, `fl64`, `lpcm`) reads as codec `PCM` with its
  `Pcm_Format` (bits, float, endianness from `enda` or the version-2 flags).
  QuickTime lists one table sample per audio frame; PCM tracks are indexed
  per chunk instead, so the index stays small for long tracks. Other audio
  layouts keep codec `Unknown` without failing the file. Writing ProRes or
  PCM returns `Unsupported`.
- **MP3:** `mp4a` whose `esds` object type is 0x6B or 0x69, and QuickTime's
  `.mp3` entry, read as codec `MP3`, one frame per sample.
- **FLAC:** the `fLaC` sample entry reads as codec `FLAC`, its `dfLa`
  metadata blocks in `audio_specific_config`, rate and channels from their
  streaminfo (the entry's 16-bit rate cannot hold rates above 65535 Hz).
  One frame per sample; writing it returns `Unsupported`.
- **AV1:** the `av01` sample entry reads as codec `AV1`, its whole `av1C`
  record (4-byte header, then the configuration OBUs) in `config`, one
  temporal unit per sample, `colr` as for the other video entries. Writing
  it returns `Unsupported`.
- **Accepted inputs:** `avc1`/`avc3`, `hvc1`/`hev1` and `mp4a`, including
  the QuickTime sound description versions 1 and 2 (in a version-0 `stsd`),
  ISO `AudioSampleEntryV1` (in a version-1 `stsd`), and an `esds` inside
  `wave`. Also 64-bit box sizes, `co64`, `stz2`, `ctts` versions 0 and 1 (read
  signed), `mvhd` anywhere in `moov`, a `moov` after `mdat`, and multiple
  tracks.
- **Defensive limits:** malformed tables return `Invalid_Data`. Samples per
  track are capped at 2^26, and every sample must lie inside the file.

## Not supported

- **Fragmented MP4:** `moof`/`mvex` returns `Unsupported`, both for reading
  and writing.
- **Multiple sample descriptions per track** return `Unsupported`.
- **Encrypted entries** (`encv`/`enca`) and compressed audio other than AAC
  keep codec `Unknown`. Their samples are still readable.
- **Edit lists** beyond one empty edit plus one rate-1 edit are not fully
  applied (`Edit.complex`).
- **Not written:** metadata (`udta`/`meta`), chapters, and `sdtp`
  dependency hints.

## Validation

```sh
odin test codec/container/mp4
bash tests/mp4_check.sh /tmp/odecs-mp4
```

The unit tests round-trip reordered video and primed audio, with and without
faststart. They cover `co64`, `hvcC` fields, parameter-set refusal, ADTS
stripping, fragmented refusal, `mvhd` after `trak`, ISO audio entry v1, and
50k samples in reversed composition order. Every truncation and a byte-corruption sweep
of a muxed file must be refused, or must read consistently without
out-of-bounds access. `tests/mp4_check.sh` uses FFmpeg/ffprobe as oracles
only; see the [movie README](../../movie/README.md).
