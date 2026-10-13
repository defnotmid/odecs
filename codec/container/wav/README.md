# WAV

Native WAV reading. `open` finds the format and data chunks; `read_frames`
then reads interleaved frames straight from the file, so opening costs a
few small reads whatever the length. The package imports only Odin `core`.

```odin
r: wav.Reader
err := wav.open(&r, "in.wav")             // or open_stream (Read_At + Size)
f := r.format                              // sample_rate, channels, bits, float, big_endian, companding, ...
bytes, e := wav.read_frames(&r, first, count) // borrowed until the next read
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
  G.711 A-law and mu-law, which `expand_g711` turns into `f32`. ADPCM and
  other compressed formats return `Unsupported`.
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
