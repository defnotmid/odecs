#!/usr/bin/env bash
# WebP fixtures for tests/webp_check.sh: libwebp's test corpus (the VP8
# conformance streams, lossless, alpha and odd-size images) at a pinned
# commit; libwebp's tools built from third_party/libwebp (dwebp, img2webp,
# webpmux, anim_dump: the oracle, never linked); dwebp's RGBA (-pam) and
# planar (-pgm) decodes of every file; and animations encoded from FFmpeg
# frames (lossless, lossy, mixed, opaque, and a hand-assembled one that
# blends semi-transparent frames and disposes some), with anim_dump's
# canvases.
#   bash tests/webp_fixtures.sh [work-dir]
set -euo pipefail
out=${1:-.work/webpfx}
mkdir -p "$out"
corpus=https://chromium.googlesource.com/webm/libwebp-test-data
commit=06ddd96e276c2c638a72d39d3c0f340afd61978c
if [ ! -d "$out/testdata" ]; then
	git clone -q "$corpus" "$out/testdata"
	git -C "$out/testdata" -c advice.detachedHead=false checkout -q "$commit"
fi
if [ ! -x "$out/build/dwebp" ]; then
	cmake -S third_party/libwebp -B "$out/build" -DCMAKE_BUILD_TYPE=Release -DWEBP_BUILD_ANIM_UTILS=ON \
		-DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_EXTRAS=OFF >/dev/null
	cmake --build "$out/build" -j 8 >/dev/null
fi
b=$out/build
mkdir -p "$out/ref"
for f in "$out"/testdata/*.webp; do
	n=$(basename "$f" .webp)
	"$b/dwebp" -quiet "$f" -pam -o "$out/ref/$n.pam"
	"$b/dwebp" -quiet "$f" -pgm -o "$out/ref/$n.pgm"
done
# Animations.
a=$out/anim
mkdir -p "$a/frames" "$a/opaque" "$a/blend"
ff=(ffmpeg -hide_banner -loglevel error -y)
"${ff[@]}" -f lavfi -i "color=c=red@0:s=200x150:d=2:r=12,format=rgba[bg];testsrc2=s=60x40:r=12:d=2,format=rgba,colorchannelmixer=aa=0.6[fg];[bg][fg]overlay=x='t*70':y='t*45':format=auto,format=rgba" "$a/frames/%03d.png"
"${ff[@]}" -f lavfi -i "testsrc2=s=180x120:r=10:d=2" "$a/opaque/%03d.png"
"$b/img2webp" -kmax 5 "$a"/frames/*.png -o "$a/lossless.webp" >/dev/null
"$b/img2webp" -lossy -q 60 "$a"/frames/*.png -o "$a/lossy.webp" >/dev/null
"$b/img2webp" -mixed "$a"/frames/*.png -o "$a/mixed.webp" >/dev/null
"$b/img2webp" -lossy -q 70 -min_size "$a"/opaque/*.png -o "$a/opaque.webp" >/dev/null
"${ff[@]}" -f lavfi -i "testsrc2=s=200x150" -frames:v 1 "$a/blend/bg.png"
"${ff[@]}" -f lavfi -i "color=c=blue@0:s=64x48,format=rgba[bg];testsrc=s=40x30,format=rgba,colorchannelmixer=aa=0.5[fg];[bg][fg]overlay=12:9,format=rgba" -frames:v 1 "$a/blend/sprite.png"
"$b/cwebp" -quiet -q 80 "$a/blend/bg.png" -o "$a/blend/bg.webp"
"$b/cwebp" -quiet -lossless "$a/blend/sprite.png" -o "$a/blend/sprite_ll.webp"
"$b/cwebp" -quiet -q 70 "$a/blend/sprite.png" -o "$a/blend/sprite_lossy.webp"
# Frames: +duration+x+y+dispose(0 none, 1 background) then +b blend / -b not.
"$b/webpmux" -frame "$a/blend/bg.webp" +100+0+0+0-b -frame "$a/blend/sprite_ll.webp" +100+20+10+0+b \
	-frame "$a/blend/sprite_lossy.webp" +100+50+30+1+b -frame "$a/blend/sprite_ll.webp" +100+60+40+0+b \
	-frame "$a/blend/sprite_lossy.webp" +100+80+60+1+b -frame "$a/blend/sprite_ll.webp" +100+40+20+0+b \
	-loop 0 -bgcolor 255,255,255,255 -o "$a/blend.webp" >/dev/null
for n in lossless lossy mixed opaque blend; do
	rm -rf "$a/ref_$n" && mkdir -p "$a/ref_$n"
	"$b/anim_dump" -pam -folder "$a/ref_$n" "$a/$n.webp" >/dev/null
done
echo "fixtures in $out"
