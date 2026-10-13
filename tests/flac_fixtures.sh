#!/usr/bin/env bash
# FLAC fixtures from the reference encoder (flac) and FFmpeg's, covering
# depths 8 to 32, mono to 7.1, compression levels (fixed and LPC
# predictors), LPC orders up to 32, large blocks, every stereo mode,
# metadata (seek table, tags, picture, padding, ID3), and FLAC in Matroska
# and MP4. Each NAME.flac gets NAME.f32, FFmpeg's decode, as the oracle.
#   bash tests/flac_fixtures.sh OUTDIR
set -euo pipefail
out=${1:?usage: flac_fixtures.sh OUTDIR}
mkdir -p "$out/src"
ff() { ffmpeg -v error -y "$@"; }
# Music-like material: chords, a sweep, and noise so LPC has work to do.
music="0.3*sin(2*PI*220*t)+0.2*sin(2*PI*277.2*t)+0.15*sin(2*PI*329.6*t)*sin(2*PI*0.3*t)+0.1*sin(2*PI*(200+800*t)*t)+0.05*(random(0)-0.5)"
music2="0.3*sin(2*PI*110*t)+0.2*sin(2*PI*440*t+1)+0.1*sin(2*PI*1500*t)*sin(2*PI*3*t)+0.05*(random(1)-0.5)"
src() { # NAME RATE CHANNELS FORMAT SECONDS
	local chans="$music" k
	for ((k = 1; k < $3; k++)); do chans="$chans|$( ((k % 2)) && echo "$music2" || echo "$music" )*$(echo "scale=2; 1 - $k / 10" | bc)"; done
	ff -f lavfi -i "aevalsrc=$chans:s=$2:d=$5" -c:a "$4" "$out/src/$1.wav"
}
src s16 44100 2 pcm_s16le 6
src s24 96000 2 pcm_s24le 4
src s32 48000 2 pcm_s32le 3
src u8 22050 1 pcm_u8 4
src s24_6ch 48000 6 pcm_s24le 3
src s16_8ch 48000 8 pcm_s16le 2
fl() { flac --silent -f "$@" 2>/dev/null; } # warns about the LIST chunk FFmpeg writes
fl -0 -o "$out/ref_l0.flac" "$out/src/s16.wav"
fl -5 -o "$out/ref_l5.flac" "$out/src/s16.wav"
fl -8 -o "$out/ref_l8.flac" "$out/src/s16.wav"
fl -8 -o "$out/ref_24_96k.flac" "$out/src/s24.wav"
fl -8 -o "$out/ref_32.flac" "$out/src/s32.wav"
fl -5 -o "$out/ref_8bit_mono.flac" "$out/src/u8.wav"
fl -8 -o "$out/ref_24_6ch.flac" "$out/src/s24_6ch.wav"
fl -5 -o "$out/ref_16_8ch.flac" "$out/src/s16_8ch.wav"
fl --lax -l 32 -b 16384 -r 15 -o "$out/ref_lax_order32.flac" "$out/src/s24.wav"
fl --lax -b 65535 -o "$out/ref_lax_block65535.flac" "$out/src/s16.wav"
fl -5 --no-seektable --no-padding -o "$out/ref_bare.flac" "$out/src/s16.wav"
fl -5 -T TITLE=gate -T ARTIST=odecs --padding=10000 -o "$out/ref_tagged.flac" "$out/src/s16.wav"
# 12-bit: the low 4 bits of 16-bit samples zeroed, so every subframe has
# wasted bits.
ff -i "$out/src/s16.wav" -af "aeval=floor(val(0)*2048)/2048|floor(val(1)*2048)/2048" -c:a pcm_s16le "$out/src/s16_wasted.wav"
fl -8 -o "$out/ref_wasted.flac" "$out/src/s16_wasted.wav"
ff -i "$out/src/s24.wav" -c:a flac -sample_fmt s32 "$out/ff_24bit.flac"
for mode in indep left_side right_side mid_side; do
	ff -i "$out/src/s16.wav" -c:a flac -ch_mode $mode -compression_level 8 "$out/ff_$mode.flac"
done
ff -i "$out/src/s24.wav" -c:a flac -compression_level 12 -exact_rice_parameters 1 -lpc_type cholesky "$out/ff_l12_cholesky.flac"
ff -i "$out/src/s16.wav" -c:a flac -lpc_type fixed "$out/ff_fixed.flac"
# A picture block and an ID3v2 tag in front of the stream.
cp "$out/ref_l5.flac" "$out/ref_picture.flac"
ff -f lavfi -i color=red:s=64x64 -frames:v 1 "$out/src/cover.png"
metaflac --import-picture-from="$out/src/cover.png" "$out/ref_picture.flac"
{ printf 'ID3\x04\x00\x00\x00\x00\x00\x0a'; head -c 10 /dev/zero; cat "$out/ref_l5.flac"; } > "$out/ref_id3.flac"
for f in "$out"/*.flac; do ff -i "$f" -f f32le "${f%.flac}.f32"; done
# FLAC inside containers, decoded through movie.Reader.
ff -i "$out/ref_l8.flac" -c:a copy "$out/in_matroska.mkv"
ff -i "$out/ref_24_96k.flac" -c:a copy "$out/in_mp4.mp4"
ff -f lavfi -i testsrc2=size=320x240:rate=30:d=4 -i "$out/ref_l5.flac" -c:v libx264 -c:a copy -shortest "$out/video_flac.mkv"
for f in "$out"/*.mkv "$out"/*.mp4; do ff -i "$f" -map 0:a -f f32le "$f.f32"; done
