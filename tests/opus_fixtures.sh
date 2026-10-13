#!/usr/bin/env bash
# Opus fixtures for tests/opus_check.sh: the RFC 8251 test vectors, libopus's
# opus_demo/opus_compare built from third_party/opus (the conformance tools
# and the loss reference's library), DTX bitstreams from opus_demo, and
# Ogg/WebM files written by FFmpeg's libopus in every mode, with FFmpeg's
# decodes of them (surround in the Opus channel order).
#   bash tests/opus_fixtures.sh [work-dir]
set -euo pipefail
out=${1:-.work/opusfx}
mkdir -p "$out"
vectors=https://opus-codec.org/static/testvectors/opus_testvectors-rfc8251.tar.gz
sum=6b26a22f9ba87b2b836906a9bb7afec5f8e54d49553b1200382520ee6fedfa55
if [ ! -d "$out/vectors/opus_newvectors" ]; then
	curl -sfL -o "$out/testvectors.tar.gz" "$vectors"
	echo "$sum  $out/testvectors.tar.gz" | sha256sum -c --quiet
	mkdir -p "$out/vectors" && tar -xzf "$out/testvectors.tar.gz" -C "$out/vectors"
fi
if [ ! -x "$out/opus-build/opus_compare" ]; then
	cmake -S third_party/opus -B "$out/opus-build" -DOPUS_BUILD_PROGRAMS=ON -DOPUS_BUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
	cmake --build "$out/opus-build" -j 8 >/dev/null
fi
ff=(ffmpeg -hide_banner -loglevel error -y)
# CELT (music), SILK and hybrid (speech) in Ogg and WebM.
"${ff[@]}" -f lavfi -i "sine=frequency=440:duration=6" -f lavfi -i "anoisesrc=d=6:c=pink:a=0.1" \
	-filter_complex "[0][1]amix=inputs=2,aformat=channel_layouts=stereo" -c:a libopus -b:a 96k -application audio "$out/celt_stereo.opus"
"${ff[@]}" -i "$out/celt_stereo.opus" -c copy "$out/celt_stereo.webm"
"${ff[@]}" -f lavfi -i "sine=frequency=1000:duration=4" -c:a libopus -b:a 64k -application audio -frame_duration 10 "$out/celt_mono.ogg"
"${ff[@]}" -f lavfi -i "sine=frequency=300:duration=5" -f lavfi -i "anoisesrc=d=5:c=brown:a=0.05" \
	-filter_complex "[0][1]amix=inputs=2" -ac 1 -c:a libopus -b:a 12k -application voip "$out/silk_mono.ogg"
"${ff[@]}" -f lavfi -i "sine=frequency=300:duration=5" -f lavfi -i "anoisesrc=d=5:c=pink:a=0.05" \
	-filter_complex "[0][1]amix=inputs=2,aformat=channel_layouts=stereo" -c:a libopus -b:a 32k -application voip "$out/hybrid_stereo.webm"
for f in "$out"/celt_*.opus "$out"/celt_*.webm "$out"/celt_*.ogg "$out/silk_mono.ogg" "$out/hybrid_stereo.webm"; do
	"${ff[@]}" -c:a libopus -i "$f" -f f32le "$f.f32"
done
# 5.1 surround: four streams (two coupled), mapping family 1. FFmpeg
# decodes to its own 5.1 order; the pan puts it back in the Opus (Vorbis)
# order the decoder outputs.
"${ff[@]}" -f lavfi -i "sine=f=220:d=5" -f lavfi -i "sine=f=330:d=5" -f lavfi -i "sine=f=440:d=5" \
	-f lavfi -i "sine=f=60:d=5" -f lavfi -i "anoisesrc=d=5:c=pink:a=0.05" -f lavfi -i "sine=f=660:d=5" \
	-filter_complex "[0][1][2][3][4][5]join=inputs=6:channel_layout=5.1" -c:a libopus -b:a 192k "$out/surround51.opus"
"${ff[@]}" -c:a libopus -i "$out/surround51.opus" -af "pan=6c|c0=c0|c1=c2|c2=c1|c3=c4|c4=c5|c5=c3" -f f32le "$out/surround51.opus.f32"
# DTX: a tone in 0.8 s bursts every 2 s over faint noise, encoded with DTX
# as hybrid (voip and audio tuning), SILK-only and CELT-only streams.
"${ff[@]}" -f lavfi -i "aevalsrc=0.3*sin(2*PI*220*t)*sin(2*PI*3*t)*lt(mod(t\,2)\,0.8)+0.0005*(random(0)-0.5):s=48000:d=12" \
	-ac 2 -f s16le "$out/dtx_in.pcm"
"${ff[@]}" -f s16le -ar 48000 -ac 2 -i "$out/dtx_in.pcm" -ac 1 -f s16le "$out/dtx_in1.pcm"
demo=$out/opus-build/opus_demo
"$demo" -e voip 48000 2 24000 -dtx "$out/dtx_in.pcm" "$out/dtx_voip.bit" >/dev/null 2>&1
"$demo" -e audio 48000 2 24000 -dtx "$out/dtx_in.pcm" "$out/dtx_audio.bit" >/dev/null 2>&1
"$demo" -e voip 48000 1 10000 -dtx "$out/dtx_in1.pcm" "$out/dtx_silk.bit" >/dev/null 2>&1
"$demo" -e restricted-lowdelay 48000 2 32000 -framesize 10 -dtx "$out/dtx_in.pcm" "$out/dtx_celt.bit" >/dev/null 2>&1
# In-band FEC (LBRR copies) for an assumed 20% loss, from vector 03's
# speech: SILK in 20, 40 and 60 ms packets, mono and stereo, and hybrid.
"${ff[@]}" -f s16le -ar 48000 -ac 2 -i "$out/vectors/opus_newvectors/testvector03.dec" -ac 1 -f s16le "$out/speech1.pcm"
speech2=$out/vectors/opus_newvectors/testvector03.dec
"$demo" -e voip 48000 1 24000 -inbandfec -loss 20 "$out/speech1.pcm" "$out/fec_silk.bit" >/dev/null 2>&1
"$demo" -e voip 48000 1 20000 -inbandfec -loss 20 -framesize 40 "$out/speech1.pcm" "$out/fec_silk40.bit" >/dev/null 2>&1
"$demo" -e voip 48000 2 32000 -inbandfec -loss 20 -framesize 60 "$speech2" "$out/fec_silk60.bit" >/dev/null 2>&1
"$demo" -e voip 48000 2 48000 -bandwidth FB -inbandfec -loss 20 "$speech2" "$out/fec_hybrid.bit" >/dev/null 2>&1
echo "fixtures in $out"
