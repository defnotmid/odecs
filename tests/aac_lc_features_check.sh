#!/usr/bin/env bash
# Decoder feature interoperability only. This script never builds binaries or
# generates fixtures. Run the feature-export unit suite serially beforehand:
#   mkdir -p .work/aac-lc-complete/features
#   odin test audio/aac/decoder -define:OICUT_AAC_FEATURE_EXPORT=true ...
# Then supply prepared native binaries:
#   AAC_DECODE_BIN=/absolute/path/decode-aac \
#   AUDIO_COMPARE_BIN=/absolute/path/audio-compare \
#     bash tests/aac_lc_features_check.sh
# Optional: AAC_FEATURES_DIR, AAC_FEATURES_WORK, FFMPEG_BIN, FFPROBE_BIN.
# All 25 primary fixtures, four signed-gain controls and the paired DRC control
# have no PNS. Compare complete
# PCM, including startup overlap and the short-CCE Stop drain; never trim delay.
# Native DRC is metadata only. The installed reference has no AAC drc_scale
# option; paired otherwise-identical DRC/no-DRC streams prove it applies no gain.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${AAC_DECODE_BIN:?set AAC_DECODE_BIN to the prepared native decoder CLI}"
: "${AUDIO_COMPARE_BIN:?set AUDIO_COMPARE_BIN to the prepared native PCM comparator}"
FFMPEG_BIN=${FFMPEG_BIN:-ffmpeg}
FFPROBE_BIN=${FFPROBE_BIN:-ffprobe}
FEATURES=${AAC_FEATURES_DIR:-.work/aac-lc-complete/features}
OUT=${AAC_FEATURES_WORK:-.work/aac-lc-complete/feature-check}

fail() { printf 'AAC-LC feature gate: %s\n' "$*" >&2; exit 1; }
for tool in "$AAC_DECODE_BIN" "$AUDIO_COMPARE_BIN" "$FFMPEG_BIN" "$FFPROBE_BIN"; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing prepared tool: $tool"
done
[[ -d "$FEATURES" ]] || fail "missing exported fixture directory: $FEATURES"
mkdir -p "$OUT"

# CLI statistics are one key=value row. Require exactly one numeric value so
# a stale/wrong binary or malformed report cannot silently satisfy the gate.
native_stat() {
  awk -v key="$1" '
    { for (i=1;i<=NF;i++) if (index($i,key "=")==1) {
        count++; value=substr($i,length(key)+2)
    } }
    END { if (count!=1 || value !~ /^[0-9]+$/) exit 1; print value }
  ' "$2"
}
probe_stat() {
  awk -v key="$1" '
    index($0,key "=")==1 { count++; value=substr($0,length(key)+2) }
    END { if (count!=1 || value=="") exit 1; print value }
  ' "$2"
}

# AAC syntax order is front SCE (center), front CPE, remaining front/side/back
# pairs, then LFE. For cc7 the center-front pair precedes the outside-front
# pair (ISO/IEC14496-3:2001 Table1.11). FFmpeg emits declared layout order. Admission
# below chooses a fixed permutation from that declared layout, never fits a
# permutation to PCM values. The cc7 wide pair is distinguished explicitly.
canonical_pan() {
  local channels=$1 layout=$2
  case "$channels:$layout" in
    '1:mono'|'1:FC') printf 'pan=%s|c0=c0' "$layout" ;;
    '2:stereo'|'2:FL+FR') printf 'pan=%s|c0=c0|c1=c1' "$layout" ;;
    '3:3.0'|'3:FL+FR+FC') printf 'pan=%s|c0=c2|c1=c0|c2=c1' "$layout" ;;
    '4:4.0'|'4:FL+FR+FC+BC') printf 'pan=%s|c0=c2|c1=c0|c2=c1|c3=c3' "$layout" ;;
    '5:5.0'|'5:5.0(side)') printf 'pan=%s|c0=c2|c1=c0|c2=c1|c3=c3|c4=c4' "$layout" ;;
    '6:5.1'|'6:5.1(side)') printf 'pan=%s|c0=c2|c1=c0|c2=c1|c3=c4|c4=c5|c5=c3' "$layout" ;;
    '7:7.0') printf 'pan=%s|c0=c2|c1=c0|c2=c1|c3=c5|c4=c6|c5=c3|c6=c4' "$layout" ;;
    '8:7.1(wide)') printf 'pan=%s|c0=c2|c1=c6|c2=c7|c3=c0|c4=c1|c5=c4|c6=c5|c7=c3' "$layout" ;;
    '8:7.1(wide-side)') printf 'pan=%s|c0=c2|c1=c4|c2=c5|c3=c0|c4=c1|c5=c6|c6=c7|c7=c3' "$layout" ;;
    *) fail "unrecognized reference channel layout: channels=$channels layout=$layout" ;;
  esac
}

passed=0
check_fixture() {
  local name=$1 channels=$2 frame_samples=$3 frames=$4
  local extension=aac transport=adts
  if [[ "$frame_samples" == 960 ]]; then extension=loas; transport=loas; fi
  local input="$FEATURES/$name.$extension" prefix="$OUT/$name"
  local -a codec_options=()
  if [[ "$extension" == aac ]]; then codec_options=(-channel_order 0); fi
  [[ -s "$input" ]] || fail "missing/empty fixture: $input"
  "$AAC_DECODE_BIN" "$input" "$prefix.native.s16le" >"$prefix.native.log" 2>"$prefix.native.err"
  for pair in "rate:48000" "channels:$channels" "frame_samples:$frame_samples" "frames:$frames" "pns:0"; do
    local key=${pair%%:*} expected=${pair#*:} actual
    actual=$(native_stat "$key" "$prefix.native.log") || fail "invalid native report: $name field=$key"
    [[ "$actual" == "$expected" ]] || fail "native report mismatch: $name $key=$actual expected=$expected"
  done
  # PNS phases require statistical comparisons. These particular exports
  # contain none, as asserted above; no PNS parity is claimed by this script.
  "$FFPROBE_BIN" -v error -strict 1 "${codec_options[@]}" -select_streams a:0 \
    -show_entries stream=codec_name,profile,sample_rate,channels,channel_layout \
    -of default=noprint_wrappers=1 "$input" >"$prefix.reference.info" 2>"$prefix.probe.err"
  local codec profile rate reference_channels layout pan
  codec=$(probe_stat codec_name "$prefix.reference.info")
  profile=$(probe_stat profile "$prefix.reference.info")
  rate=$(probe_stat sample_rate "$prefix.reference.info")
  reference_channels=$(probe_stat channels "$prefix.reference.info")
  layout=$(probe_stat channel_layout "$prefix.reference.info")
  [[ "$codec" == aac || "$codec" == aac_latm ]] || fail "unexpected codec: $name codec=$codec"
  [[ "$profile" == LC && "$rate" == 48000 && "$reference_channels" == "$channels" ]] || fail "reference config mismatch: $name profile=$profile rate=$rate channels=$reference_channels"
  pan=$(canonical_pan "$channels" "$layout")
  # Decoder options precede -i. No reference encoding, resampling, downmixing,
  # priming removal or final trimming is permitted. DRC uses the paired gate.
  "$FFMPEG_BIN" -hide_banner -v error -y -strict 1 "${codec_options[@]}" -i "$input" \
    -map 0:a:0 -af "$pan" -c:a pcm_s16le -f s16le "$prefix.reference.s16le" \
    >"$prefix.reference.log" 2>"$prefix.reference.err"
  local expected_bytes=$((frames * frame_samples * channels * 2)) bytes
  for output in "$prefix.native.s16le" "$prefix.reference.s16le"; do
    bytes=$(wc -c <"$output")
    [[ "$bytes" -eq "$expected_bytes" ]] || fail "PCM length mismatch: $name file=$output bytes=$bytes expected=$expected_bytes"
  done
  "$AUDIO_COMPARE_BIN" pair "$prefix.native.s16le" "$prefix.reference.s16le" >"$prefix.compare.log"
  cat "$prefix.compare.log"
  printf 'AAC-LC feature: name=%s channels=%s frame_samples=%s frames=%s transport=%s reference_layout=%s canonical_filter=%s\n' \
    "$name" "$channels" "$frame_samples" "$frames" "$transport" "$layout" "$pan"
  passed=$((passed + 1))
}

for frame_samples in 1024 960; do
  for channels in 1 2 3 4 5 6 7 8; do
    check_fixture "standard_${channels}ch_${frame_samples}" "$channels" "$frame_samples" 4
  done
done
check_fixture pce_tag_order_drc_3ch 3 1024 4
check_fixture pce_tag_order_no_drc_3ch 3 1024 4
cmp "$OUT/pce_tag_order_drc_3ch.reference.s16le" "$OUT/pce_tag_order_no_drc_3ch.reference.s16le" || fail "reference applied DRC gain to the paired control"
cmp "$OUT/pce_tag_order_drc_3ch.native.s16le" "$OUT/pce_tag_order_no_drc_3ch.native.s16le" || fail "native DRC metadata unexpectedly changed PCM"
printf 'AAC-LC DRC discriminator: paired reference and native PCM each byte-identical; no gain application\n'
for domain in false true; do
  for common in false true; do
    check_fixture "cce_target_tns_domain${domain}_common${common}" 2 1024 4
  done
done
for independent in false true; do
  check_fixture "cce_independent${independent}_short120" 2 960 5
  check_fixture "cce_independent${independent}_short128" 2 1024 5
done
for deltas in minus1_minus1 plus1_plus1 minus3_plus1 plus3_minus1; do
  check_fixture "cce_signed_delta_${deltas}" 2 1024 4
  tns=$(native_stat tns "$OUT/cce_signed_delta_${deltas}.native.log") || fail "invalid signed-gain TNS report: $deltas"
  [[ "$tns" == 0 ]] || fail "signed-gain control unexpectedly has target TNS: $deltas tns=$tns"
done
[[ "$passed" -eq 30 ]] || fail "manifest count mismatch: passed=$passed"
printf 'AAC-LC feature gate: 25 primary fixtures plus 4 signed-gain controls and 1 paired DRC control passed (max error <=2 s16); no PNS, encoder quality or complete conformance claim\n'
