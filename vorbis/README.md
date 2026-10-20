# Vorbis

Vorbis I audio decoding, written from the Vorbis I specification. It reads
the identification and setup headers into flat tables, then turns audio
packets into interleaved `f32` PCM. Ogg Vorbis and Vorbis in
WebM/Matroska decode through [`audio`](../audio/README.md) (a `media` native
codec), which places packets from their block sizes and the granule positions.

```odin
import vorbis "../vorbis"

d: vorbis.Decoder
err := vorbis.init_decoder(&d, identification, setup) // the first and third packets
defer vorbis.destroy_decoder(&d)
pcm := make([]f32, vorbis.max_frames(&d) * d.channels)
for packet in audio_packets {
	frames, e := vorbis.decode_packet(&d, packet, pcm) // interleaved; none for the first packet
}
// Before decoding (or without a decoder): shape := vorbis.packet_shape(identification, setup)
// (the setup read without building its tables); vorbis.packet_blocksize(shape, first_bytes)
// and vorbis.packet_frames(previous, current) give every packet's output.
```

## Data layout

**Setup, read once:**
- **Codebooks** keep their decode tables and VQ vectors in shared pools, each
  book an offset into them: a 10-bit lookup table, longer codewords sorted for
  binary search, and every VQ vector unpacked to `f32`. Codewords are assigned
  as the specification says (the lowest available, in entry order), on a flat
  binary trie that records the shallowest free depth under each node.
- **Floor 1** keeps its points' X order and each point's neighbours, computed
  once.

**Per packet**, `init_decoder` has allocated everything, so decoding
allocates nothing:
1. Floor Y values for each channel.
2. Residue vectors into per-channel spectra (type 2 through one interleaved
   vector).
3. Inverse coupling.
4. Each floor drawn as a multiply over its spectrum.
5. The inverse MDCT: a DCT-IV through a quarter-size complex FFT, on split
   real and imaginary planes.
6. The window, then overlap-add into the caller's PCM.

## Not decoded

**Floor type 0** (LSP) has not been written by encoders since 2001.
Streams that use it return `.Unsupported`.

## Verification

`tests/vorbis_check.sh` fetches and builds the pinned libvorbis and libogg,
then compares every fixture from `tests/vorbis_fixtures.sh`:
- libvorbis at qualities −1 to 10 and 128 kb/s;
- mono to 7.1, at 8 to 96 kHz;
- transients (short blocks), and a file shorter than one block;
- FFmpeg's own Vorbis encoder.

All have libvorbis' exact frame count, at 134.9 dB SNR or better (float
rounding; the largest difference is 4e-7). The fuzz pass runs 300 mutations
per fixture under AddressSanitizer. `odin test vorbis` checks:
- the specification's codeword example;
- the IMDCT against its definition;
- the helper functions;
- the identification header.

**Granule positions.** The Ogg granules are applied as the encapsulation
spec says. A stream whose first page implies a negative start loses those
samples. libvorbis can only drop what it still holds in its buffer, so for
out-of-spec streams whose first page carries many packets (FFmpeg
stream-copy cuts), odecs starts later than libvorbis. The spec limits a
start trim to the first two packets, so in-spec streams agree.

## Speed

The 15 fixtures decode in 46 ms in total, against libvorbis' 64 ms (0.72×):
one core, `-microarch:native`, each side's best of five.
