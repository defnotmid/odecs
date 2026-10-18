# WAV

Native WAV reading. `open` finds the format and data chunks and the first
`smpl` loop; `read_frames` then reads interleaved frames straight from the
file, so opening costs a few small reads whatever the length, and `read`
converts them into a caller's `i16` or `f32` buffer. The package imports
Odin `core` and `codec/common` (the sample conversions).

```odin
r: wav.Reader
err := wav.open(&r, "in.wav")             // or open_stream (Read_At + Size), open_bytes (borrowed)
f := r.format                              // sample_rate, channels, bits, float, big_endian, sample, ...
n := r.frames                              // from the header alone
loop, has_loop := r.loop.?                 // smpl: start and end frames, end inclusive
bytes, e := wav.read_frames(&r, first, count) // as stored, borrowed until the next read
frames, re := wav.read(&r, first, pcm)     // pcm: []i16 or []f32, interleaved; optional leading-channel count
wav.close(&r)
```

- **Containers:** RIFF/WAVE, big-endian RIFX, and RF64/BW64 with 64-bit
  sizes from `ds64` (files over 4 GiB from field recorders and broadcast
  tools). Other chunks (`LIST`, `bext`, `fact`, `junk`, ...) are skipped,
  with RIFF's even-size padding.
- **Samples:** `WAVE_FORMAT_PCM` (unsigned 8-bit, signed 16/24/32-bit),
  `WAVE_FORMAT_IEEE_FLOAT` (32/64-bit), `WAVE_FORMAT_EXTENSIBLE` with
  either subtype (valid bits and channel mask reported; narrower samples
  are left-justified, so reading at the container width is exact), and
  G.711 A-law and mu-law. ADPCM and other compressed formats return
  `Unsupported`.
- **Conversion** (`read`, through `common.to_i16` and `common.to_f32`):
  to `i16`, narrower integers scale up exactly, wider ones and floats
  (×32768) round half away from zero and saturate; to `f32`, integers
  divide by 2^(bits−1), which is exact, and floats clamp to [−1, 1]. NaN is
  silence; G.711 expands to its 16-bit table values.
- **Loops:** the first loop of a `smpl` chunk, before or after the data;
  a loop that runs backwards is ignored.
- **Unfinished files:** a data size of zero or `0xFFFFFFFF` (a writer that
  never came back to fill it in, such as one writing to a pipe), or one
  running past the end of the file (an interrupted recording), means the
  data runs to the end of the file. A trailing partial frame is dropped.
- **Checks:** the block alignment must equal channels × bytes per sample,
  channels are 1..64, and every truncation of a valid file opens with what
  it holds or returns an error.

`movie.Reader` plays WAV files as audio-only movies. `bash tests/wav_check.sh`
compares every supported format with FFmpeg (bit-exact, whole files and
after random seeks) and fuzzes the reader.

```sh
odin test codec/container/wav
```
