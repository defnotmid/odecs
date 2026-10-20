# MP3

Native MPEG-1, MPEG-2 and MPEG-2.5 Audio Layer III decoding and `.mp3`
reading. The package imports only Odin `core`.

```odin
r: mp3.Reader
err := mp3.open(&r, "in.mp3")          // or open_stream (Read_At + Size)
d := new(mp3.Decoder)
data, e := mp3.read_frame(&r, i)        // r.frames is the #soa frame index
f, de := mp3.decode_frame(d, data)       // f.pcm[c][:f.header.samples], planar f32
start := mp3.frame_sample(&r, i)         // on the gapless timeline
mp3.close(&r)
```

- **Scope:** Layer III at all nine sample rates, mono, stereo, dual
  channel and joint stereo (mid/side and intensity, MPEG-1 and MPEG-2
  rules), long, short, mixed, start and stop blocks, the bit reservoir and
  CRC-protected frames. Layers I and II and free-format streams return
  `Unsupported`. A frame whose main data begins before the bytes the
  decoder has seen decodes as silence and reports `complete = false`.
- **Accuracy:** every conformance stream in minimp3's `vectors/` (17
  streams: MPEG-1 and MPEG-2, mono and stereo, block switching, Huffman and
  side-information stress, mode switching) is within one 16-bit step of the
  reference PCM, 109–134 dB PSNR where the standard asks for 96 dB.
  Against FFmpeg the largest difference is 3e-6 of full scale.
- **Layout:** each channel keeps its own planes. The hybrid filterbank
  writes subband samples time-major (18 × 32), so the synthesis reads each
  time slot contiguously; its matrixing adds one 64-wide cosine row per
  subband and its windowing one 32-wide row per tap, and the IMDCTs add one
  row of their cosine tables per input line. Those loops run over contiguous
  outputs, vectorise as written, and doubled decode speed over the
  dot-product form (60 s of 44.1 kHz stereo in 55 ms on one thread; FFmpeg
  takes 28–46 ms).
- **Files:** ID3v2 tags (several), ID3v1, APE and other trailing data are
  skipped. Every frame is indexed at open from its 4-byte header, read
  through a 64 KiB window, and must match the first frame's version and
  rate. A leading Xing/Info frame is metadata; its LAME extension gives the
  encoder delay and padding, trimmed with the decoder's 529-sample delay as
  FFmpeg does.

Lineage is in [PROVENANCE.md](../PROVENANCE.md): the front end is a
restructured port of minimp3 (CC0), the tables are generated from minimp3
and PDMP3 (public domain) by [`tools/tables`](../tools/tables/README.md), and the filterbank
follows the standard's definitions. `bash tests/mp3_check.sh` runs the
conformance streams, malformed streams, FFmpeg comparisons, MP3 in MP4,
MOV and Matroska through `video.Reader`, and a fuzz pass.

```sh
odin test mp3
```
