# WebM / Matroska

Native demuxing of WebM and Matroska. On open, the reader indexes every
block of every track into a flat per-track sample table: offset, size,
timestamp in nanoseconds, duration, keyframe flag, and the `BlockAdditional`
with `BlockAddID` 1. Seeking therefore needs no `Cues`. The package imports
only Odin `core`.

```odin
r: webm.Reader
err := webm.open(&r, "in.webm")          // or open_stream (Read_At + Size)
for t in r.tracks { /* codec (VP9, H264, AAC, ...), width/height, alpha, color, ... */ }
p, e := webm.read_sample(&r, track, index) // p.data, p.additional (VP9 alpha)
k := webm.keyframe_at(&r.tracks[i], pts_ns)
webm.close(&r)
```

- **Structure:** EBML header (`webm` or `matroska`), the first `Segment`,
  `Info` (`TimecodeScale`, `Duration`), `Tracks`, and every `Cluster` with
  `SimpleBlock` and `BlockGroup` (`Block`, `BlockAdditions`, `ReferenceBlock`,
  `BlockDuration`). Unknown elements are skipped. Clusters may have unknown
  sizes. A file cut off mid-write (an interrupted recording) opens with
  every complete block before the cut, even when the `Segment` and last
  `Cluster` state sizes past the end of the file.
- **Lacing:** Xiph, EBML and fixed. Laced frames after the first are spaced
  by `DefaultDuration`, or by the block's duration divided evenly.
- **Track metadata:** `CodecID`, named in `codec` for VP8, VP9, AV1,
  H.264 (`V_MPEG4/ISO/AVC`, avcC in `CodecPrivate`), H.265
  (`V_MPEGH/ISO/HEVC`, hvcC), Opus, Vorbis, AAC (`A_AAC`, and the legacy
  `A_AAC/MPEG2/LC` and `A_AAC/MPEG4/LC`, which get an AudioSpecificConfig
  built from the rate and channels), FLAC (`A_FLAC`, metadata blocks in
  `CodecPrivate`), MP3 (`A_MPEG/L3`) and PCM (`A_PCM/INT/LIT`,
  `A_PCM/INT/BIG`, `A_PCM/FLOAT/IEEE`, described by `pcm_format`). Also
  pixel and display size, `AlphaMode`, `Colour` (matrix, primaries,
  transfer, range, bits, chroma siting), sample rate, channels, bit depth,
  `CodecDelay`, and the last block's `DiscardPadding` as `end_discard`.
- **Content encodings:** header stripping (`ContentCompAlgo` 3, which older
  mkvmerge versions applied by default) is undone by `read_sample`. Tracks
  with zlib or other compression, or encryption, keep codec `Unknown`.
- **I/O:** element headers are read through a 4 KiB window, so opening costs
  about one small read per block rather than reading the file.
- **Defensive limits:** sizes are checked against their parents, lacing
  against the block, and frames against 2^26 per track. Every truncation of
  a valid document opens with what it has or returns an error.

```sh
odin test container/webm
```

## Writing VP9 WebM

```odin
w: webm.Writer
err := webm.create(&w, "out.webm", {
    width = width, height = height,
    alpha = true, default_duration = 33_333_333,
}) // or create_stream with a borrowed Write_At stream
err = webm.write_sample(&w, colour_packet, pts_ns, keyframe, alpha_packet, duration_ns)
err = webm.finish(&w)
webm.destroy(&w)
```

- Video-only, one VP9 track, BT.709 limited range, 8-bit. Packets are borrowed
  during `write_sample` and immediately written; no encoder/runtime dependency.
  Dimensions may be odd. The writer does not parse packets: the caller must
  supply matching colour/alpha frame types and dimensions.
- Nanosecond API timestamps are floored to millisecond ticks (TimecodeScale
  1,000,000). The first frame must be a keyframe. PTS must be nonnegative and
  strictly increase **in ticks**, so frame intervals below 1 ms are unsupported.
- Opaque output uses SimpleBlock. Alpha output uses BlockGroup, ReferenceBlock
  for inter frames, and BlockAdditions/BlockMore with BlockAddID 1. AlphaMode
  and MaxBlockAdditionID are 1; every frame must supply an alpha packet.
- A new Cluster starts at each keyframe and before the signed relative block
  time would exceed 32767 ticks. Cues index keyframes at Cluster starts.
- SeekHead precedes Info and Tracks; finish patches its Cues pointer, Duration,
  Segment size and the last Cluster size. Other Cluster sizes patch at rollover.
  A missing final duration uses DefaultDuration, or the preceding PTS delta.
  A lone frame at PTS 0 with no duration gets a Void in place of Duration,
  since Matroska requires a positive Duration.
- `finish` is idempotent and **required**. `destroy` closes an owned file and
  frees memory, but never silently finishes an interrupted recording. Borrowed
  streams remain open. I/O errors latch: later writes/finish return IO_Error.
  A failed scratch reservation returns Out_Of_Memory before anything is
  written, so the call can be retried. Destroy before reinitializing a writer.
- No audio, alternate codecs, multiple tracks, lacing, non-seekable output,
  reordering, live streaming or faststart Cues relocation in this phase.

The writer's tests cover reader round-trip, alpha, gaps/cluster rollover,
SeekHead targets, patched sizes and errors. `tests/vp9_encode_check.sh` adds
FFmpeg/libvpx byte equality, video.Reader planar round-trip, ffprobe checks,
and headless Chromium compositing. See the
[encoder README](../../video/vp9/encoder/README.md) for exact results and limits.
