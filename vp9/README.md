# VP9

`vp9` holds what the encoder shares with the decoder: constants,
probability contexts with their defaults and backward adaptation, inverse
transforms, intra and inter prediction, the loop filter and the mode-info
grid. `vp9/decoder` parses the bitstream (bool decoder, headers,
partitions, mode info, motion vector prediction, coefficient tokens) and
manages frames and references. `vp9/encoder` writes profile 0 key/inter
frames from planar input (including independent alpha streams); its API,
verification and efficiency limits are in [its README](encoder/README.md). Both are written from the *VP9 Bitstream &
Decoding Process Specification v0.7*. `tables.odin` is generated from that
document by [`tools/tables`](../tools/tables/README.md): all 82
tables, checked against their declared dimensions.

```odin
import vp9d "../vp9/decoder"

d: vp9d.Decoder
vp9d.init_decoder(&d, pool)                 // optional caller Work_Pool
picture, shown, err := vp9d.decode_packet(&d, packet) // frame or superframe
// picture.planes8 (8-bit) or planes16, strides in samples; valid until the next call
vp9d.destroy_decoder(&d)
```

An alpha stream (WebM `BlockAdditional` 1) is a second VP9 stream; decode
it with a second `Decoder` and use its luma as the alpha plane.

## Scope

- Profiles 0–3: 8, 10 and 12 bits; 4:2:0, 4:2:2, 4:4:4 and sRGB (G, B, R
  planes); 4:4:0 decodes per the specification but has no fixture and no
  `media` frame layout.
- Key, inter and intra-only frames, hidden frames in superframes and
  `show_existing_frame`.
- Compound prediction, switchable interpolation filters, segmentation,
  lossless (Walsh–Hadamard), error-resilient and frame-parallel modes,
  tile columns and rows, and references of another size (scaled motion
  compensation).
- Backward probability adaptation, including the count bookkeeping it needs.
- **Errors:** malformed headers, missing references, impossible sizes and
  truncated data return `Invalid_Data`, or `Unsupported` for reference
  scaling beyond 2x down or 16x up. A bool decoder reads zeros past its data.

## Exactness

Every decoded frame matches FFmpeg's decoder bit for bit on 14 fixtures from
libvpx. They cover the profiles, bit depths and chroma formats above, alpha,
four tile columns, two tile rows, lossless, segmentation (`aq-mode` 3),
error-resilient mode, odd sizes, a two-pass stream with compound prediction
and hidden alt-ref frames, and RGB. Scaled references and intra-only frames
are implemented to the specification but had no libvpx fixture.

## Parallelism and performance

Tile columns of a tile row decode in parallel. The loop filter runs in
anti-diagonal waves of superblocks: superblock (r, c) needs (r, c - 1) and
(r - 1, c + 1), so all superblocks with equal `2r + c` are independent and
each wave is one ordinary `Work_Pool` run. Motion compensation (8-tap
filters in native-width lanes) and the loop filter (sixteen edge lines as
`#simd` lanes, transposed for vertical edges) are vectorized.

The decoder keeps what each later reader needs in its own record or grid,
written once when a block is decoded: Motion cells for motion vector
prediction (gathered once per block), above/left edge contexts, Filter_Cell
records for the loop filter, per-frame reference scales. Transforms run as
lanes with the size a compile-time constant, the loop filter in i16 lanes
over pairs of 8x8 cells. Single-thread speed against FFmpeg is in the root
README's "Decoding speed" table (1.60× at 8 bits, 1.38× at 10).

## Spec errata applied

- 9.3.2: intra frames take partition probabilities from `kf_partition_probs`
  (the text has the condition inverted).
- 8.8.1: the delta-free filter level applies when `loop_filter_delta_enabled`
  is 0 (the text names `loop_filter_delta_update`).
- 9.3.4: the "special case" for `more_coefs` counts is missing from v0.7.
  Counting `more_coefs` each time it is read matches libvpx and FFmpeg.
