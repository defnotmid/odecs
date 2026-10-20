# Table generators

Writes the codecs' generated table files from their reference sources. The C
sources are the pinned trees that `bash tools/fetch_third_party.sh` fetches
into `third_party/` (see [THIRD_PARTY_REFERENCES.md](../../THIRD_PARTY_REFERENCES.md));
VP9's tables come from its specification's text.

```sh
odin build tools/tables -out:.work/tables
.work/tables opus > audio/opus/tables.odin
.work/tables silk > audio/opus/silk_tables.odin
.work/tables webp > image/webp/tables.odin
.work/tables mp3  > audio/mp3/tables.odin
.work/tables h265 > video/h265/scan_tables.odin
.work/tables vp9 .work/vp9-spec.txt > video/vp9/tables.odin
```

The C generators take the `third_party` directory as an optional second
argument. Each finds a table's C initializer by name, so a moved or renamed
table fails rather than producing a partial file, and checks the counts it
depends on.

| Generator | Source | Tables |
| --- | --- | --- |
| `opus` | libopus `celt/`: `modes.c`, `static_modes_float.h`, `quant_bands.c`, `celt.c`, `celt.h`, `rate.c`, `cwrs.c` | band edges, allocation, pulse cache, MDCT window, energy models and means, TF and small ICDFs, PVQ sizes (rows flattened with offsets) |
| `silk` | libopus `silk/tables_*.c`, `pitch_est_tables.c`, `resampler_rom.*`, `table_LSF_cos.c`, `define.h` | every SILK ICDF, codebook and filter; jagged tables as CSR |
| `webp` | libwebp `src/dec/`: `tree_dec.c`, `quant_dec.c`, `vp8l_dec.c` | VP8 coefficient and mode probabilities, quantizer steps, the lossless distance map |
| `mp3` | minimp3 `minimp3.h`, PDMP3 `pdmp3.c` | Huffman lookup, scalefactor bands and partitions, the synthesis window |
| `h265` | Kvazaar `src/tables.c`, `src/tables.h` | coefficient and coefficient-group scans |
| `vp9` | the VP9 specification's text | all 82 `name[dims] = {...}` tables |

## VP9

The input is the text of the *VP9 Bitstream & Decoding Process Specification*
v0.7 (2017-02-22), made with poppler's `pdftotext -layout`:

```sh
curl -o .work/vp9-spec.pdf https://storage.googleapis.com/downloads.webmproject.org/docs/vp9/vp9-bitstream-specification-v0.7-20170222-draft.pdf
pdftotext -layout .work/vp9-spec.pdf .work/vp9-spec.txt
```

| File | SHA-256 |
| --- | --- |
| PDF | `92a5bc772d11572c2f119680998ee202e249d075469515fe43bbb7febb51b963` |
| text (pdftotext 26.08.0) | `6fa72b853d825a25089b4ba04d980410add57d00f1ae0e694a864ca02eb70cd4` |

Dimensions and symbolic entries resolve through the constants of section 3
(`NAME value`) and the value tables of section 7 (`value NAME`). Element
counts must match the dimensions, a short innermost row is zero-filled as in
a C initializer, and each table gets the narrowest integer type that holds
its values (scans are all `u16`). Another `pdftotext` version may lay the text
out differently; the check is that the output is unchanged.
