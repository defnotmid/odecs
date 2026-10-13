#!/usr/bin/env bash
# Native AAC-LC / FFmpeg interoperability and basic signal preservation.
set -euo pipefail
cd "$(dirname "$0")/.."
D=${WORK:-.work/aac-check}
mkdir -p "$D"
odin build tests/encode_aac.odin -file -o:speed -out:"$D/encode"
odin build tests/decode_aac.odin -file -o:speed -out:"$D/decode"
odin build tests/aac_check.odin -file -out:"$D/check"
for rate in 44100 48000; do
 for channels in 1 2; do
  for signal in tone transient noise; do
   p="$D/$rate-$channels-$signal"
   "$D/check" signal "$rate" "$channels" "$signal" "$p.pcm"
   "$D/encode" "$p.pcm" "$rate" "$channels" "$((channels*64000))" "$p.native.aac" > "$p.encode.log"
   ffmpeg -v error -y -f s16le -ar "$rate" -ac "$channels" -i "$p.pcm" -c:a aac -aac_pns 0 -b:a "$((channels*64000))" "$p.ff.aac"
   for encoder in native ff; do
    "$D/decode" "$p.$encoder.aac" "$p.$encoder.native.pcm" > "$p.$encoder.decode.log"
    ffmpeg -v error -y -i "$p.$encoder.aac" -f s16le "$p.$encoder.ff.pcm"
    "$D/check" compare "$p.$encoder"
   done
  done
 done
done

# A weak, explicit quality floor catches accidental all-zero noise output.
# This is signal preservation, not a perceptual quality or matched-rate claim.
"$D/check" snr "$D"

# Exercise PNS explicitly: phases may differ, length and energy must agree.
ffmpeg -v error -y -f s16le -ar 48000 -ac 2 -i "$D/48000-2-noise.pcm" \
    -c:a aac -aac_pns 1 -aac_ms 1 -b:a 48000 "$D/pns.aac"
"$D/decode" "$D/pns.aac" "$D/pns.native.pcm" > "$D/pns.log"
ffmpeg -v error -y -i "$D/pns.aac" -f s16le "$D/pns.ff.pcm"
"$D/check" pns "$D"
echo 'AAC gate: 24 cross-decoding cases, 12 signal-preservation cases, and PNS passed'
