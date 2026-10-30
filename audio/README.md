# Audio

The suite's one audio path. It recognises the container from the first
bytes:
- MP4/M4A/MOV;
- WebM/Matroska;
- WAV, including RF64;
- FLAC;
- MP3;
- Ogg.

It decodes the first audio track to interleaved `f32` or `i16`, at the
file's own rate, with all its channels or the first few. The supported
codecs are AAC-LC, PCM, FLAC, MP3, Opus, ALAC and Vorbis. Mixing down and
resampling are left to the caller.

```odin
import audio "deps:oicut/audio"

info, e := audio.info(data)           // headers only: present, codec, sample_rate, channels, samples, loop
a, err := audio.decode(data)          // a whole file in memory as f32; audio.destroy_audio(&a)
n, e1 := audio.decode_into(data, out) // into a caller's []i16 or []f32 of samples * channels
n, e1 = audio.decode_into(data, out2, channels = 2) // the first two channels (FL, FR)

r: audio.Reader                       // or a file, with seeking
err = audio.open(&r, "song.flac")     // or open_stream; channels = N keeps the first N
n, e2 := audio.read(&r, pcm)          // []f32 or []i16; frames written; End_Of_Stream at the end
audio.seek(&r, 12.34)
audio.close(&r)
```

**Samples.** Channels come in WAVE order (FL, FR, FC, LFE, ...) whatever
the codec stores, and `channels = N` keeps the first N. `f32` is in
[-1, 1]. `i16` is converted from what the codec decodes:
- **PCM** (WAV and the containers' raw PCM): `common.to_i16`, as `wav.read`.
- **FLAC and ALAC**: from their integers (`common.scale_i16`), as
  `flac.interleave`.
- **The lossy codecs**: their `f32`, rounded by `common.to_i16`.

WAV and FLAC reads are bit-identical to `wav.read` and `flac.interleave`, in
both types.

**Loops.** `Info.loop` is a sample loop in frames, `[start, end)` with `end`
exclusive. It comes from WAV's first `smpl` loop (whose `end` is inclusive,
so `Info.loop.end` is one past it), a FLAC file's `APPLICATION "riff"` `smpl`
chunk, or `LOOPSTART`/`LOOPLENGTH` Vorbis comments (Ogg Vorbis and Opus,
native FLAC). It is as the file states it, so check it lies within
`samples`.

## How it is built

`audio.Reader` owns the opened file: the container reader and the first
audio track's decoding through `audio.Decoder`. That decoder is the one
implementation of AAC, FLAC, MP3, Opus, ALAC and Vorbis packet decoding, and
`media`'s native provider delegates to it. `audio` imports only audio codecs
and containers: an audio-only program links no video codec and needs no
video codec's licence notice. A file with video is opened the same way:
[`video`](../video/README.md)'s reader embeds an `audio.Reader` and reads
its video track from the same container.

**Positions.** PCM index zero is time zero:
- priming and padding are trimmed (edit lists, LAME tags, Opus pre-skip,
  Matroska `CodecDelay`, Ogg granule positions);
- a delayed track starts with silence.

**Packet placement:**
- **Ogg and Matroska** packets are placed from their own lengths. These
  are Opus frame sizes, AAC's fixed frames, PCM block sizes, and each Vorbis
  packet's block size read from its first byte. Matroska timestamps are
  rounded to milliseconds, so they cannot place samples.
- **Seeking** pre-rolls what each codec needs: one packet for the AAC and
  Vorbis overlap, 13 MP3 frames for the bit reservoir, and 80 ms for Opus.

**Sizing.** `decode` reads the track's sample count at open, allocates once,
and fills; `decode_into` fills the caller's buffer, sized from `info`. A
stream claiming more than 2³⁰ samples (4 GiB) is refused, because a few
bytes of a stream can claim far more.

## Verification

**Against miniaudio**, which the suite used before
(`tests/audio_facade_compare.odin`):
- **WAV and FLAC:** identical.
- **MP3 and Vorbis:** compared by SNR after aligning the outputs, with the
  frame counts reported.

**Each codec's own gate:**
- `tests/vorbis_check.sh`: libvorbis.
- `tests/wav_check.sh`, `flac_check.sh`, `mp3_check.sh`, `opus_check.sh`,
  `mkv_check.sh` and `alpha_check.sh`: FFmpeg, through the video reader.

**The additions** (`audio_test.odin`): `i16` and `f32` reads of WAV in every
sample format, and of FLAC, equal `wav.read` and `flac.interleave` bit for
bit, with and without a channel limit; the loop sources.
`tests/audio_types_check.odin` checks real files: `i16` equals
`common.to_i16` of the `f32` decode (except where the source is wider than
`f32`: 32-bit integers and `f64`), kept channels equal the full decode's
first ones, and reads that alternate the two types give the same samples.
It passes on 92 fixture files across every codec.

**Fuzzing:** `tests/audio_fuzz.odin` runs mutation fuzzing under
AddressSanitizer.
