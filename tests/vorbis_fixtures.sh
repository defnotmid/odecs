#!/usr/bin/env bash
# Ogg Vorbis fixtures: libvorbis (through FFmpeg) at qualities -1 to 10,
# mono to 7.1, 8 to 96 kHz, a few seconds long and one under a block, and
# FFmpeg's own Vorbis encoder (other floor and residue setups). Development
# only; nothing is committed. (FFmpeg's encoder takes stereo only.)
#   bash tests/vorbis_fixtures.sh [dir]   (default .work/vorbis-fixtures)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-.work/vorbis-fixtures}
mkdir -p "$out/src"
ff() { ffmpeg -v error -y "$@"; }
# Music-like material: chords, a sweep, and noise.
music="0.3*sin(2*PI*220*t)+0.2*sin(2*PI*277.2*t)+0.15*sin(2*PI*329.6*t)*sin(2*PI*0.3*t)+0.1*sin(2*PI*(200+800*t)*t)+0.05*(random(0)-0.5)"
music2="0.3*sin(2*PI*110*t)+0.2*sin(2*PI*440*t+1)+0.1*sin(2*PI*1500*t)*sin(2*PI*3*t)+0.05*(random(1)-0.5)"
# Transients for short blocks: clicks every quarter second.
clicks="0.6*sin(2*PI*1000*t)*exp(-60*mod(t\\,0.25))"
src() { # NAME RATE CHANNELS SECONDS [EXPR]
	local base=${5:-$music} chans k
	chans=$base
	for ((k = 1; k < $3; k++)); do chans="$chans|$( ((k % 2)) && echo "$music2" || echo "$base" )*$(echo "scale=2; 1 - $k / 10" | bc)"; done
	[ -f "$out/src/$1.wav" ] || ff -f lavfi -i "aevalsrc=$chans:s=$2:d=$4" -c:a pcm_f32le "$out/src/$1.wav"
}
src stereo44 44100 2 6
src stereo48 48000 2 4
src mono22 22050 1 4
src mono8 8000 1 3
src hi96 96000 2 2
src s51 48000 6 3
src s71 48000 8 2
src clicks 44100 2 4 "$clicks"
src tiny 44100 2 0.01
enc() { # NAME SOURCE ARGS...
	local name=$1 source=$2
	shift 2
	[ -f "$out/$name.ogg" ] || ff -i "$out/src/$source.wav" "$@" "$out/$name.ogg"
}
for q in -1 0 3 6 10; do enc "lv_q${q}_stereo44" stereo44 -c:a libvorbis -q:a "$q"; done
enc lv_q4_stereo48 stereo48 -c:a libvorbis -q:a 4
enc lv_q2_mono22 mono22 -c:a libvorbis -q:a 2
enc lv_q0_mono8 mono8 -c:a libvorbis -q:a 0
enc lv_q5_hi96 hi96 -c:a libvorbis -q:a 5
enc lv_q4_51 s51 -c:a libvorbis -q:a 4
enc lv_q3_71 s71 -c:a libvorbis -q:a 3
enc lv_q5_clicks clicks -c:a libvorbis -q:a 5
enc lv_q3_tiny tiny -c:a libvorbis -q:a 3
enc lv_128k stereo44 -c:a libvorbis -b:a 128k
enc ff_stereo44 stereo44 -c:a vorbis -strict -2
ls "$out"/*.ogg | wc -l
