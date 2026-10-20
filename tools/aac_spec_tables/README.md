# AAC primary-standard tables

This native Odin tool reads the primary ISO/IEC 14496-3:2001 standard's text.
It does not import a codec package, read another codec's source, or use the
current table values to construct its output. It independently parses all
Huffman tables (4.A.1–4.A.12), scale-factor-band tables (4.73–4.85), TNS limits
(4.103), and the low-frequency mapping (4.55).

Use the [primary standard PDF](https://ossrs.net/lts/zh-cn/assets/files/ISO_IEC_14496-3-AAC-2001-7f4d0b3622b322cb72c78f85d91c449f.pdf)
and `pdftotext -layout` to retain table rows. The tool checks every symbol,
prefix-freedom, complete offset rows, explicit bracketed 960/120 values,
strict band ordering, all rate maps, and all TNS limits. An incomplete or
malformed extraction fails; it never fills a missing value from current code.

```sh
odin build tools/aac_spec_tables -out:.work/aac-lc-complete/aac-spec-tables
.work/aac-lc-complete/aac-spec-tables \
  .work/aac-lc-complete/ISO14496-3.txt \
  aac/tables.odin \
  .work/aac-lc-complete/normative-tables.odin
sha256sum .work/aac-lc-complete/ISO14496-3.pdf \
  .work/aac-lc-complete/ISO14496-3.txt \
  .work/aac-lc-complete/normative-tables.odin
```

The generated file contains only independently reconstructed normative
constants and native selection helpers. It is emitted after the primary
tables pass internal validation, even if comparison with current source
reports a mismatch. A mismatch names the book/symbol or array/index and
returns failure. Existing source and attribution are never overwritten.
Replace the current constants only after this gate and codec tests pass;
retain attribution for anything whose replacement provenance remains open.

The 2026-10-04 gate reconstructed and matched 12 codebooks / 1,362 symbols,
26 SWB arrays, 52 mapped rate tables and 26 TNS limits. The generated source
passed `odin check` and matched the replacement production constants. Recorded
SHA-256 values are:

| Artifact | SHA-256 |
|---|---|
| Primary PDF | `96bc11c0eeac1d2b597f5963428b0a308c872f5f1f0b24574ed5a6f530540edc` |
| `pdftotext -layout` text | `46fcd34f514a4fdbfb9e2a1d3d8d691674890859c2d4738469d1d9724bf35c1c` |
| Generated Odin before formatting | `8251e65ecbb7d864a107821ea831824a5b9ba894a2cc871a5a086faca77be6f6` |

This is evidence for these normative constants. It does not establish the
provenance of unrelated implementations or authorize removing their notices.
