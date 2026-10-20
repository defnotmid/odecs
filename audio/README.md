# Audio

The suite's one audio path. It recognises the container from the first
bytes:
- MP4/M4A/MOV;
- WebM/Matroska;
- WAV, including RF64;
- FLAC;
- MP3;
- Ogg.

It decodes the first audio track to interleaved `f32`, at the file's own
rate and channel count. The supported codecs are AAC-LC, PCM, FLAC, MP3,
Opus, ALAC and Vorbis. Mixing down and resampling are left to the caller.

```odin
import audio "deps:odecs/audio"

a, err := audio.decode(data)          // a whole file in memory; audio.destroy_audio(&a)
info, e := audio.info(data)           // present, codec, sample_rate, channels, samples

r: audio.Reader                       // or a file, with seeking
err = audio.open(&r, "song.flac")     // or open_stream
n, e2 := audio.read(&r, pcm)          // frames written, interleaved; End_Of_Stream at the end
audio.seek(&r, 12.34)
audio.close(&r)
```

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
and fills. A stream claiming more than 2³⁰ samples (4 GiB) is refused,
because a few bytes of a stream can claim far more.

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

**Fuzzing:** `tests/audio_fuzz.odin` runs mutation fuzzing under
AddressSanitizer.
