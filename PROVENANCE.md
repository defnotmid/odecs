# Provenance

odecs is MIT licensed. This file records what each package was written from,
and what it was ported from, with each source's license. Everything ported
is under a license compatible with MIT (MIT, BSD-2-Clause, BSD-3-Clause,
Apache-2.0, CC0, public domain), and the notices those licenses require
are kept beside the code. No code from copyleft projects (FFmpeg, x264, x265)
is in odecs; they are used only as binaries to make fixtures and check output.

The reference sources are pinned in
[THIRD_PARTY_REFERENCES.md](THIRD_PARTY_REFERENCES.md) and fetched by
`tools/fetch_third_party.sh`; they are never committed.

## Ported code

| Package | Source | License | Notice |
| --- | --- | --- | --- |
| `opus` | libopus 1.6.1 | BSD-3-Clause | `opus/LICENSE-libopus.txt` |
| `webp` | libwebp 1.6.0 | BSD-3-Clause, with Google's patent grant | `webp/LICENSE-libwebp.txt` |
| `h265/decoder`, `h265` | gen2brain/h265 (Go) | MIT | `h265/LICENSE-gen2brain-h265.txt` |
| `h265/decoder`, `h265` | OxideAV oxideav-h265 (Rust), cross-reference | MIT | `h265/LICENSE-oxideav-h265.txt` |
| `h265/encoder`, `h265` | Kvazaar | BSD-3-Clause | `h265/LICENSE-kvazaar.txt` |
| `h264/decoder` | OpenH264 (CABAC tables) | BSD-2-Clause | `h264/decoder/LICENSE-openh264.txt` |
| `alac` | Apple Lossless Audio Codec | Apache-2.0 | `alac/LICENSE-alac.txt` |
| `mp3` | minimp3; PDMP3 | CC0 1.0; public domain (Unlicense) | none required |

### Opus

`opus` decodes Opus as RFC 6716 (SHA-256
`41caac5240a4a22661efd0031d5b7aee48f3c0bde3b2cdcee8165932e485f98c`), with the
RFC 8251 updates (`86abdb8c0fa1b0b6e1b9c1f324163ca152a8d2d9debd10461da3d56438489ecd`),
describes it. Its normative reference is libopus, whose code the RFC
contains. The decoder is a restructured Odin port of libopus:
- CELT from the float decoder: `celt_decoder.c` (with its concealment), `bands.c`, `vq.c`, `cwrs.c`, `rate.c`, `quant_bands.c`, `pitch.c`, `celt_lpc.c` and `entdec.c`;
- SILK from its fixed-point decoder (`dec_API.c`, `decode_*.c`, `NLSF*.c`, `PLC.c`, `CNG.c`, `stereo_*.c`, the IIR/FIR resampler and the arithmetic macros);
- the Opus layer from `opus_decoder.c` and `opus_multistream_decoder.c`;
- `tools/tables` copies the tables.

The FFT and inverse MDCT are our own, written from the RFC's description. The
Ogg reader follows RFC 3533 and Ogg Opus RFC 7845.

### WebP

`webp` decodes WebP as RFC 9649 describes it. The container and
lossless formats were written from libwebp's specification documents, from
which the RFC was made:
- `doc/webp-container-spec.txt`, SHA-256 `72740333623ba43cf1a6baee10979619a95fdd7be8e9dd025fe4866a7a6771f9`;
- `doc/webp-lossless-bitstream-spec.txt`, SHA-256 `11d4d940aaef8a1b500c90b5d873bea2d5aa3dec0944b1086bd9aaaf7db9600b`.

VP8 (RFC 6386), and the details the documents leave to the reference, were ported (restructured) from libwebp's decoder:
- `vp8_dec.c`, `tree_dec.c`, `quant_dec.c`, `frame_dec.c` and `dsp/dec.c`;
- `vp8l_dec.c`, `huffman_utils.c` and `dsp/lossless.c`;
- `alpha_dec.c` and `dsp/filters.c`;
- `dsp/yuv.h` and `dsp/upsampling.c`;
- `demux/anim_decode.c`.

`tools/tables` copies the tables.

### ALAC

`alac` is a restructured Odin port of Apple's open-source ALAC decoder
(`ALACDecoder.cpp`, `ag_dec.c`, `dp_dec.c`, `matrix_dec.c`, `ALACBitUtilities.c`,
and `ALACAudioTypes.h`).

### MP3

`mp3`'s front end (side information, scalefactors including MPEG-2's
partitions, Huffman decoding, intensity and mid/side stereo, reordering,
alias reduction, the bit reservoir and the Xing/LAME tag) is a restructured
port of minimp3. `tools/tables` copies minimp3's Huffman,
scalefactor-band and partition tables and PDMP3's synthesis window. The
hybrid filterbank and polyphase synthesis follow the standard's definitions
as PDMP3 implements them; their cosine tables and windows are computed.

### JPEG

`jpeg` is our own decoder, written from ITU-T T.81 (baseline and
progressive, Huffman coding). Its IDCT is the Loeffler, Ligtenberg and
Moschytz factorisation with 13-bit fixed-point constants. libjpeg-turbo is
the oracle and the speed to meet. Where T.81 leaves room, odecs follows its
behaviour, so the output is identical to libjpeg-turbo at its defaults:
- the IDCT's rounding;
- the alternating rounding of fancy upsampling;
- the YCbCr constants;
- the colour space chosen from JFIF, Adobe and the component IDs.

No libjpeg-turbo code is used. The Huffman lookup tables follow the approach
stb_image takes (public domain).

### Vorbis

`vorbis` is our own decoder, written from the Vorbis I specification in
libvorbis' `doc/` (the LaTeX sources). `vorbis/tables.odin` copies the
specification's floor 1 inverse-dB table. libvorbis is the oracle and the
speed to meet. No libvorbis code is used. The Ogg granule handling in
`audio` follows the specification's Ogg encapsulation appendix.

### H.265

The decoder began as a port of gen2brain/h265's `hevc/*.go` modules, cross-referenced with oxideav-h265.
- **gen2brain/h265 ports:** the source comments name them in `h265/scaling.odin` and in these files of `h265/decoder`:
  - `cabac`, `ctu`, `deblock`, `dpb`, `getbits`, `headers`, `inter`, `interpred`, `intrapred`, `mvpred`, `nal`, `residual`, `sao`, `scaling` and `slice`;
  - `cabac_tables.odin`, generated from `hevc/cabac_tables.go`.
- **oxideav-h265 cross-references:** many of the same files point to its modules for spec-section structure, and `h265/transform.odin` names its `src/transform.rs` for the range-extension equations.
- **Encoder:** `h265/encoder/inter.odin`'s `scale_mv` is ported from the decoder.

The encoder follows Kvazaar in:
- `h265/encoder/cabac.odin`: a port of `cabac.c`;
- `h265/encoder/sao.odin`: its SAO decisions (`sao.c`, `sao_shared_generics.h`);
- `h265/encoder/tables.odin`: context constants (`context.c`, `encoderstate.h`) and reference-pixel counts;
- `h265/scan_tables.odin`: generated from `tables.c` and `tables.h` by `tools/tables`;
- design references in `h265/encoder/inter.odin` (interpolation filters, motion search), `h265/encoder/simd.odin` (transform shifts) and `h265/transform.odin` (scaling-list quantization).

Tests derived from these projects:
- `h265/decoder/cabac_test.odin` ports gen2brain's `cabac_test.go`;
- `h265/decoder/rext_test.odin` cites equations as OxideAV and gen2brain do;
- `h265/encoder/cabac_golden_test.odin` and `ipol_test.odin` use goldens generated with Kvazaar.

HEVC alpha layers follow H.265 Annex F.

### H.264

`h264/decoder/cabac_tables.odin` holds the normative CABAC,
normalization and default scaling tables, transcribed via OpenH264. The rest
of `h264` was written from the H.264 specification. `tests/test_decode.odin`,
`tests/test_zhling.odin`, `tests/vectors.sh` and the viewer use OpenH264's
reference streams as fixtures.

## Written from specifications

- **AAC:** `aac/tables.odin` is generated from ISO/IEC 14496-3:2001 by `tools/aac_spec_tables/main.odin`, which checks 12 codebooks (1,362 symbols), 26 SWB arrays, 52 rate tables and 26 TNS limits. Inputs and reproduction are in `tools/aac_spec_tables/README.md`. (An earlier table transcription from OxideAV's oxideav-aac was replaced by it.)
- **ProRes:** SMPTE RDD 36.
- **VP9:** the *VP9 Bitstream & Decoding Process Specification* v0.7 (2017-02-22, SHA-256 `92a5bc772d11572c2f119680998ee202e249d075469515fe43bbb7febb51b963`). Its 82 tables are generated from the document's text (`pdftotext -layout`) by `tools/tables`. Three places where the text is wrong or incomplete are listed in `vp9/README.md`. `vp9/encoder` inverts the normative syntax/bool subdivision and reconstructs with the shared decoder primitives. `vp9/forward.odin` prepares fixed-point DCT/ADST analysis bases from the normative synthesis constants and reverses the lossless WHT lifting steps; these are our own implementations, not libvpx ports. `webm/writer.odin` follows Matroska/WebM EBML and the VP9 BlockAdditional alpha mapping. No third-party source was ported for the encoder or the writer; FFmpeg, libvpx and Chromium are binary test oracles only.
- **AV1:** the *AV1 Bitstream & Decoding Process Specification* 1.0.0 with Errata 1 (SHA-256 `ec44e9fc42c4e5851faa879a1818dcb9014d834bbdd9420ccca7dcea05a3abe9`), and Vulkan's `VK_KHR_video_decode_av1` chapter.
- **VideoToolbox:** Apple's CoreMedia, CoreVideo and VideoToolbox headers and documentation; `media/videotoolbox` declares the few functions it calls.
- **FLAC:** RFC 9639 (SHA-256 `8906404937771aba300e1f7810534efbb8ef722a5a9970e11beaee858c966a13`). Its unit tests embed the RFC's appendix D example files.
- **Containers:** WebM/Matroska and its codec mappings, WAV (RIFF/WAVE, `WAVE_FORMAT_EXTENSIBLE`, EBU Tech 3306 RF64, ITU-T G.711), MP4/QuickTime (ISO base media file format, QuickTime File Format), Ogg (RFC 3533, RFC 7845).
- **H.264 and H.265:** ITU-T H.264 and H.265, beyond the ports above.

## Oracles and reading only

None of the following is linked into odecs or copied into it:
- **FFmpeg (LGPL)** was used as a binary: to write fixtures, decode reference pictures and PCM, and read bitstreams (`trace_headers`).
  - The H.265 decoder's CABAC decision uses the technique of FFmpeg's branchless `get_cabac`, computing both outcomes and masking. That is an idea, not code: the routine is the H.265 specification's DecodeDecision, written in Odin with the specification's tables.
  - While chasing an AV1 GPU fault, FFmpeg's `vulkan_av1.c` and `av1dec.c`, and Mesa's `radv_video.c` and `ac_vcn_dec.c` (MIT), were read to compare what each passes to the driver. Nothing was copied; the parser and frontend were written and verified first.
- **x264, x265, HM, SVT-AV1, libaom, rav1e, libdav1d, libvpx, the `flac` tool, `opus_demo`/`opus_compare`, libwebp's tools** were used as binaries, for fixtures and reference output.
- **Development harnesses that link reference libraries:** `tests/reference_benchmark.sh` (with `tests/x264_benchmark.cpp`, `tests/x265_benchmark.cpp` and `tests/ffmpeg_benchmark.cpp`), `tests/aac_benchmark.sh` (with `tests/reference_audio.c`), and the libopus loss reference `tests/opus_loss_ref.c`. They are our own code, are not part of the library, and build only in `.work/`.

## Demo assets

`demo/` (an [onimite](https://github.com/defnotmid/onimite) script, not part of the library) commits three SIL OFL 1.1
fonts and a VP9-alpha WebM made from fframes' MIT-licensed avatar clip; their
notices are in `demo/LICENSES/`. Its larger inputs are not committed.

## Runtime boundaries

- The codec packages use only this repository's code and Odin's `core`/`base` libraries.
- `media/vulkan` and `h264/encoder/compute_device.odin` load the system Vulkan loader at runtime through Odin's `vendor:vulkan` bindings.
- The viewer uses `vendor:sdl3`.
- `shaders/build.sh` compiles the Slang shaders to the SPIR-V that is embedded in the code.
