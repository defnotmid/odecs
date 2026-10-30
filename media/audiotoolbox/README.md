# AudioToolbox provider

`media/audiotoolbox` is a system-tier (`media.Tier.System`) AAC provider for
macOS, on Apple's AudioConverter. oicut's own AAC-LC codec stays first in
`Automatic`; this provider takes what it refuses, chiefly HE-AAC and HE-AAC v2,
and is an AAC-LC encoder behind it. Mono and stereo only. Off Apple platforms
`probe` reports `Unavailable`, so the provider can be listed everywhere;
`video.Writer` lists it.

- **Decoding:** raw AAC packets with the AudioSpecificConfig in
  `Config.extradata` (wrapped in an ES descriptor as AudioToolbox's magic
  cookie), or ADTS frames (configured from the first header). AudioFormat's
  format list picks the richest layer the configuration signals, so HE-AAC
  decodes at twice the core rate and HE-AAC v2 to stereo. Output is
  interleaved `f32` at the decoded rate; a timed packet's `sample_index` is
  scaled to it. Draining flushes the samples the decoder holds back.
- **Encoding:** 1024-sample `f32` frames to raw AAC-LC packets at
  `Config.bit_rate` (Apple's default when zero). The first packet's
  `sample_index` is minus Apple's priming (2112 samples), so a container
  trims it as it trims oicut's own 1024.
- **What reaches it:** `media.open` falls back only at open. A configuration
  that signals HE-AAC explicitly (AudioSpecificConfig object type 5 or 29, as
  MP4 files carry it) is refused by the native decoder at open and decoded
  here. HE-AAC signalled implicitly (an LC configuration or ADTS header with
  SBR found only in the stream) opens natively and is refused at the first
  SBR payload; list this provider alone to decode such a stream. The `audio`
  and `video` readers decode audio through the `audio` package, not through
  `media` providers.

On the M4 (macOS 27), `odin test media/audiotoolbox` encodes 80 frames of a
stereo tone through Apple's encoder and decodes them back at their position
(41.5 dB, priming 2112), and decodes oicut's AAC through Apple against oicut's
own decoder (138.5 dB). HE-AAC v1 and v2 made by `afconvert`, decoded here
with an explicit configuration, match `afconvert`'s own decoding sample for
sample, length included; AAC-LC through this provider matches it to 133.9 dB.
