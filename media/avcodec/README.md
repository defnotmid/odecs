# libavcodec provider

`media/avcodec` is a system-tier (`media.Tier.System`) H.264 and H.265 provider
that loads `libavutil` and `libavcodec` at runtime through `core:dynlib`. Nothing
is linked at build time, and when the libraries or requested codec are absent on
the host machine, `probe` reports `Unavailable` (or `Unsupported` for unaccepted
configurations).

## Runtime loading and ABI safety

- **Soname search:** `ensure_api` tries major versions `63` down to `58` for
  `libavcodec` (and `61` down to `56` for `libavutil`) across Linux/BSD
  (`libavcodec.so.*`), macOS (`libavcodec.*.dylib`) and Windows
  (`avcodec-*.dll`).
- **AVOptions and accessors:** `AVCodecContext` field offsets change between
  major FFmpeg releases, so contexts are configured through `av_opt_set*`,
  `av_opt_set_image_size`, `av_opt_set_pixel_fmt`, `av_opt_set_q`,
  `av_opt_set_video_rate` and `av_get_pix_fmt*` rather than struct layout.
- **Admission by opening:** `probe` opens a codec context with `avcodec_open2`
  and closes it immediately, so builds that omit an encoder or decoder (such as
  `ffmpeg-free` without HEVC or `libx264`) are detected accurately at probe
  time.
- **Tier ordering:** `media.open` tries `Hardware` (`Vulkan`, `VideoToolbox`),
  then `Native`, then `System` (`AVCodec`): libavcodec decodes and encodes only
  what neither admits, in practice H.264 and H.265 without `OICUT_PATENTED`. `Preference.Require_Hardware` never
  admits `AVCodec`.
