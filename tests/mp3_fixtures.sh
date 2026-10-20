#!/usr/bin/env bash
# MP3 fixtures from LAME (through FFmpeg's libmp3lame): CBR and VBR,
# MPEG-1 at 32/44.1/48 kHz, MPEG-2 at 22.05 and 16 kHz, MPEG-2.5 at 8 and
# 11.025 kHz, mono and joint stereo, ID3v2 with cover art, ID3v1, no Xing
# tag, and MP3 in MP4, MOV and Matroska. NAME.f32 is FFmpeg's decode.
#   bash tests/mp3_fixtures.sh OUTDIR
set -euo pipefail
out=${1:?usage: mp3_fixtures.sh OUTDIR}
mkdir -p "$out/src"
ff() { ffmpeg -v error -y "$@"; }
music="0.3*sin(2*PI*220*t)+0.2*sin(2*PI*277.2*t)+0.15*sin(2*PI*329.6*t)*sin(2*PI*0.3*t)+0.1*sin(2*PI*(200+800*t)*t)+0.05*(random(0)-0.5)"
music2="0.3*sin(2*PI*110*t)+0.2*sin(2*PI*440*t+1)+0.1*sin(2*PI*1500*t)*sin(2*PI*3*t)+0.05*(random(1)-0.5)"
# Transients make LAME switch to short and mixed blocks.
clicks="0.6*sin(2*PI*90*t)*exp(-mod(t\,0.37)*25)+0.3*(random(2)-0.5)*exp(-mod(t+0.1\,0.29)*40)" # \, escapes lavfi's separator
ff -f lavfi -i "aevalsrc=$music|$music2:s=44100:d=6" -c:a pcm_s16le "$out/src/stereo44.wav"
ff -f lavfi -i "aevalsrc=$music+$clicks|$music2+$clicks:s=48000:d=5" -c:a pcm_s16le "$out/src/transients48.wav"
ff -f lavfi -i "aevalsrc=$music:s=32000:d=4" -c:a pcm_s16le "$out/src/mono32.wav"
lame() { ff -i "$1" -c:a libmp3lame "${@:3}" "$out/$2"; }
lame "$out/src/stereo44.wav" cbr128.mp3 -b:a 128k
lame "$out/src/stereo44.wav" vbr_q2.mp3 -q:a 2
lame "$out/src/stereo44.wav" cbr320.mp3 -b:a 320k
lame "$out/src/transients48.wav" transients48.mp3 -b:a 192k
lame "$out/src/transients48.wav" transients_vbr.mp3 -q:a 0
lame "$out/src/mono32.wav" mono32.mp3 -b:a 64k
lame "$out/src/stereo44.wav" mpeg2_22k.mp3 -ar 22050 -b:a 64k
lame "$out/src/stereo44.wav" mpeg2_16k_mono.mp3 -ar 16000 -ac 1 -b:a 32k
lame "$out/src/stereo44.wav" mpeg25_8k.mp3 -ar 8000 -ac 1 -b:a 16k
lame "$out/src/transients48.wav" mpeg25_11k.mp3 -ar 11025 -b:a 32k
lame "$out/src/stereo44.wav" no_xing.mp3 -b:a 160k -write_xing 0
lame "$out/src/stereo44.wav" id3v1.mp3 -b:a 128k -id3v2_version 0 -write_id3v1 1 -metadata title=gate
ff -f lavfi -i color=blue:s=64x64 -frames:v 1 "$out/src/cover.png"
ff -i "$out/src/stereo44.wav" -i "$out/src/cover.png" -map 0 -map 1 -c:a libmp3lame -b:a 128k -c:v copy -id3v2_version 3 -metadata title=gate "$out/id3v2_cover.mp3"
for f in "$out"/*.mp3; do ff -i "$f" -map 0:a -f f32le "${f%.mp3}.f32"; done
# MP3 in containers, decoded through video.Reader.
ff -i "$out/vbr_q2.mp3" -c:a copy "$out/in_mp4.mp4"
ff -i "$out/cbr128.mp3" -c:a copy "$out/in_mov.mov"
ff -i "$out/transients48.mp3" -c:a copy "$out/in_matroska.mkv"
ff -f lavfi -i testsrc2=size=320x240:rate=25:d=5 -i "$out/transients48.mp3" -c:v libx264 -c:a copy -shortest "$out/video_mp3.mp4"
for f in "$out"/*.mp4 "$out"/*.mov "$out"/*.mkv; do ff -i "$f" -map 0:a -f f32le "$f.f32"; done
