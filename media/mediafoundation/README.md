# Media Foundation provider

`media/mediafoundation` is a system-tier (`media.Tier.System`) H.264 and H.265
provider for Windows. It runs the synchronous transforms Windows ships:
Microsoft's H.264 decoder and encoder, and its HEVC decoder where the HEVC
Video Extensions are installed. `mfplat.dll` is loaded at runtime with
`core:dynlib`, so nothing is linked. Off Windows, or where Media Foundation is
missing (N editions without the Media Feature Pack, Windows Server without the
Media Foundation feature), `probe` reports `Unavailable`, so the provider can
be listed on every platform. `video.Reader` and `video.Writer` list it before
[`avcodec`](../avcodec/README.md).

- **Admission:** `probe` enumerates the synchronous transforms for the
  configuration and admits it only if one takes the media types. Hardware
  transforms are asynchronous and not used; Vulkan Video covers the GPU.
- **Decoding:** 4:2:0 at 8 bits (H.264) or 8 and 10 bits (HEVC). Each access
  unit goes in as one sample; frames come out in display order, NV12 or P010,
  and are copied into tight planar planes (P010 shifted to 10-bit values),
  cropped to the minimum display aperture. An HEVC alpha layer's NAL units
  are left out, so such a stream decodes its colour layer.
- **Encoding:** 8-bit 4:2:0 from planar or interleaved chroma, I and P
  pictures in low-latency mode, a keyframe every `gop_size` frames, and `qp`
  through the encoder's quality mode where it accepts one (an encoder that
  refuses keeps its default rate control). Output is Annex B; a first packet
  without parameter sets gets the output type's sequence header. Windows
  ships no software HEVC encoder, so H.265 encoding is refused unless one is
  installed.

`odin test media/mediafoundation` encodes 30 frames through Media Foundation,
decodes them back and checks every frame (luma above 30 dB). Without Media
Foundation it logs that and passes; off Windows it checks the provider
reports itself unavailable.
