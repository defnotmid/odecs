# Apple ProRes

`prores` holds the bitstream syntax: frame and picture headers, slice
layout, scan orders, quantizer scale and entropy codebooks. `video/prores/decoder`
decodes frames. Both are written from SMPTE RDD 36 (Apple ProRes Bitstream
Syntax and Decoding Process). No encoder exists yet. The syntax package is
shared so that one can write the same tables, and `common`'s bit writer
already builds the unit test frames.

```odin
import proresd "../prores/decoder"

d: proresd.Decoder
proresd.init_decoder(&d, pool)        // optional caller Work_Pool for slices
f, err := proresd.decode_frame(&d, sample) // one QuickTime sample = one frame
// f.planes[0..2] Y, Cb, Cr and f.alpha: u16 samples, f.strides in samples
proresd.destroy_decoder(&d)
```

## Scope

| Profile | FourCC | Output |
| --- | --- | --- |
| 422 Proxy, LT, Standard, HQ | `apco`, `apcs`, `apcn`, `apch` | 10-bit 4:2:2 |
| 4444, 4444 XQ | `ap4h`, `ap4x` | 12-bit 4:4:4, alpha at 12 bits |

- **Interlaced** frames hold two field pictures; fields are woven into
  alternate rows in the order the header gives.
- **Alpha** is 8- or 16-bit, run-length coded, and scaled to the output
  depth by repeating its top bits. Alpha may stop after the last row inside
  the picture (Apple's encoder does this in a partial bottom macroblock
  row); the rows below the picture repeat the last value.
- **Slices** are independent, so `decode_frame` runs them on the caller's
  `Work_Pool`. Each slice keeps its coefficients on its own stack; the
  decoder keeps its planes and slice records between frames and allocates
  again only when a larger frame arrives.
- **Errors:** a truncated or malformed frame returns `Invalid_Data` without
  reading outside the frame; unknown header versions, chroma formats or
  alpha types return `Unsupported`.

## Exactness

The inverse transform is the ideal one, an 8-lane `#simd` float IDCT. RDD 36
specifies the IDCT by accuracy rather than by integer arithmetic, so
decoders differ in the last bit. Against FFmpeg's fixed-point IDCT, colour
samples differ by at most 1 on 0.9–6.7% of samples (mean 0.01–0.08). Alpha is
bit-exact, as are the clipping range (4..1019 at 10 bits, 4..4091 at 12 bits)
and the 12-bit 4:4:4 output layout. Fixtures and the comparison:
[`tests/alpha_check.sh`](../../tests/alpha_check.sh).

## Performance

1080p decode speed against FFmpeg's `prores`, on one pinned core and with 16
threads each (packets in memory, decoding only), is in
[BENCHMARKS.md](../../BENCHMARKS.md) (`bash tests/compare.sh run decode/prores`).
