# FLAC

Native FLAC decoding (RFC 9639) and native `.flac` file reading. The
package imports only Odin `core`.

```odin
r: flac.Reader
err := flac.open(&r, "in.flac")          // or open_stream (Read_At + Size)
d: flac.Decoder
flac.init_decoder(&d, r.info)
flac.seek(&r, sample)                       // optional: the frame holding `sample`
p, e := flac.read_frame(&r)                 // p.data, p.first_sample, p.block_size
f, used, de := flac.decode_frame(&d, p.data) // f.planes[c][:f.header.block_size]
flac.interleave(f, pcm)                     // pcm: []f32 or []i16; optional leading-channel count; or the i32 planes
flac.destroy_decoder(&d)
flac.close(&r)
```

Inside other containers, frames come from the demuxer (Matroska `A_FLAC`,
MP4 `fLaC`) and `parse_metadata` reads the configuration they carry.
`codec/media` exposes the decoder as codec `FLAC`, and `movie.Reader` plays
`.flac` files and FLAC tracks in MKV and MP4.

- **Scope:** 4 to 32 bits per sample, 1 to 8 channels, fixed and variable
  blocking, block sizes up to 65535, constant, verbatim, fixed (orders
  0–4) and LPC (orders 1–32) subframes, wasted bits, both Rice parameter
  widths with escaped partitions, and left/side, side/right and mid/side
  stereo. Frame headers that defer rate or depth to streaminfo use it.
  Every frame's CRC-8 and CRC-16 are checked; the forbidden patterns of
  section 5 are refused.
- **Layout:** each subframe decodes into its channel's own `i32` plane, so
  channels stay planar until the optional interleave. The seek table is
  `#soa`, and seeking searches its sample column.
- **Arithmetic:** widths follow appendix A. Residuals fit 32 bits;
  predictions use `i32` accumulators only where depth + coefficient
  precision + log2(order) is at most 32, `i64` otherwise. The side channel
  of 32-bit stereo needs 33 bits and decodes into an `i64` plane. Rice
  values are formed in `u64` (their unary part is bounded by the frame)
  and must fit the 32 bits the format allows. Odin integers wrap rather than
  trap, so out-of-spec input yields wrong samples that the CRC rejects,
  never undefined behaviour.
- **Reading `.flac`:** frames are found without decoding them. A frame
  ends at the next sync code where the CRC-16 of the bytes since its start
  is zero and a valid header follows; sync codes are found with
  `core:bytes`, and the CRC (slicing by 8) is continued only from candidate
  to candidate. A leading ID3v2 tag and a trailing ID3v1 tag are skipped.
  Seeking starts from the seek table's last point before the target (once
  it is verified), bisects over verified frames to within 64 KiB, then steps
  frame by frame; opening and seeking never read the whole file. When
  streaminfo has no sample count, `total_samples` finds the last frame.
- **Speed** (one thread, 60 s files): 16-bit stereo level 8 decodes in 34 ms
  plus 3 ms of frame finding, 24-bit 96 kHz in 60 + 12 ms; FFmpeg takes
  33 and 73 ms for the same files end to end. Unrolling LPC orders up to 12
  at compile time (`$N` recursion) and taking cached Rice codewords with a
  single refill account for 16 + 14 ms and 53 + 28 ms of those totals.

`bash tests/flac_check.sh` decodes 22 fixtures from the reference encoder
and FFmpeg (8 to 32 bits, mono to 7.1, compression levels 0 to 12, LPC
order 32, 65535-sample blocks, every stereo mode, wasted bits, tags,
pictures, ID3) and requires the streaminfo MD5 to match, the samples to
equal FFmpeg's bit for bit, and 50 random seeks to land exactly; it also
checks FLAC in Matroska and MP4 through `movie.Reader` and fuzzes the reader
and decoder.

```sh
odin test codec/flac
```
