# H.265

Native H.265 (HEVC) encoding and decoding: Main, Main 10 and the
range-extension tools, 4:0:0 to 4:4:4.

- `h265`: shared frames, tables, transforms (DCT, DST-VII, transform skip), quantization, scaling lists and scans.
- `h265/encoder`: the encoder, with tiles searched on the caller's `Work_Pool`.
- `h265/decoder`: the decoder, including HEVC alpha layers (Annex F auxiliary pictures).

Hardware H.265 (Vulkan Video) is in [`media/vulkan`](../media/vulkan/README.md), and
[`media`](../media/README.md) picks between them.

## Decoder

```odin
import h265d "../h265/decoder"

d: h265d.Decoder
h265d.init_decoder(&d)
defer h265d.destroy_decoder(&d)
// for each NAL unit: h265d.decode_nal(&d, nal, &pictures); at the end: h265d.flush_decoder(&d, &pictures)
```

The decoder accepts every conformant Main/Main 10/RExt stream rather than
refusing tools:
- multiple slices and dependent slice segments, tiles and wavefronts;
- 4:0:0, 4:2:0, 4:2:2 and 4:4:4, at bit depths up to 16 (validated at 8 and 10);
- PCM, transform skip, implicit and explicit residual DPCM, transquant bypass and rotation;
- scaling lists, weighted prediction, temporal MVP, long-term references and reference list modification;
- SAO and deblocking.

Screen-content extensions (palette, ACT, cross-component prediction) and error
concealment are out of scope.

## Encoder

```odin
import h265 "../h265/encoder"

h265.init_encoder(&enc, {width = 1920, height = 1080, qp = 26, bit_depth = 8})
defer h265.destroy_encoder(&enc)
// set_source per frame, encode_frame, then flush_encoder
```

Defaults code one slice of 64x64 CTUs with intra and P prediction, CABAC,
deblocking and SAO. Everything else is opt-in in `Config` (each changes the
bitstream only when enabled):
- **Structure:** B pictures and a hierarchical GOP, multiple references, periodic closed IDRs.
- **Partitions and transforms:** AMP, inter and intra transform trees, transform skip and RDPCM, PCM.
- **Prediction tools:** weighted prediction, temporal MVP, scaling lists (default or flat).
- **Parallel coding:** tiles (searched in parallel, output independent of the thread count) and wavefronts.
- **Formats:** 10-bit, and 4:0:0, 4:2:2 and 4:4:4.
- **Rate control:** CQP, ABR, CBR or CRF; level selection.
- **Signalling:** VUI colour and timing, HRD parameters, and recovery-point, decoded-picture-hash and mastering-display SEIs.

Not yet:
- the buffering-period and picture-timing SEIs;
- a lookahead complexity model;
- rate-based level constraints;
- chroma intra mode search (the encoder signals "derived from luma");
- encoder-side long-term references and list modification;
- wavefront row pipelining across threads.

- **Alpha layer:** `Config.layer` codes colour (`Base_With_Alpha`: a VPS
  declaring an AuxId 1 layer, the alpha channel information SEI on each
  IRAP) or the alpha plane (`Alpha`: nuh_layer_id 1, SPS/PPS id 1) with two
  encoders; `interleave_alpha` joins their access units in Apple's order.
  The VPS extension, alpha-layer SPS and SEI match a real VideoToolbox
  encode field for field.

## Verification

- **Package tests:** `odin test h265/encoder` and `odin test h265/decoder`, covering headers, CABAC, prediction, residuals, filters, RPS, PCM, RDPCM, alpha, picture lifetime and output order.
- **Byte-exactness of every encoder feature:** our reconstruction, our decoder and FFmpeg n9.0.1 agree on complete streams. Tools that libx265 or HM can also produce are cross-checked with their streams.
- **The decoder** reproduces the gen2brain/h265 test corpus byte for byte, plus HM and libx265 streams for tiles, wavefronts, RDPCM, PCM and scaling lists.
- **Command-line tools:** `tests/encode_h265.odin` and `tests/decode_h265.odin` encode and decode from the command line (`encode_h265 in.yuv W H FRAMES out.265 [--qp N] [--bitdepth 10] [--tiles CxR] [--wpp] [--tmvp] ...`). `tests/encode_timing_h265.odin` and `tests/decode_timing_h265.odin` time the codec with resident input, as the median of 7 runs.

## Provenance

The decoder began as a port of gen2brain/h265 (Go, MIT), cross-referenced with
OxideAV's oxideav-h265 (Rust, MIT). The encoder's CABAC engine, SAO decision,
context tables and scans follow Kvazaar (BSD-3-Clause). Their notices are
kept here as `LICENSE-gen2brain-h265.txt`, `LICENSE-oxideav-h265.txt` and
`LICENSE-kvazaar.txt`; details are in [PROVENANCE.md](../PROVENANCE.md).
