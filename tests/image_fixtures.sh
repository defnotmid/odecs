#!/usr/bin/env bash
# Image fixtures for tests/image_check.sh, generated from pinned material (a
# frame of OpenH264's 1080p fixture and assets/logo.svg where it renders) with ImageMagick,
# libjpeg-turbo's cjpeg and gifsicle. Development only; nothing is committed.
#   bash tests/image_fixtures.sh [dir]   (default .work/image-fixtures)
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-.work/image-fixtures}
mkdir -p "$out"
src=$out/src
mkdir -p "$src"
[ -f "$src/photo.png" ] || ffmpeg -v error -y -i third_party/openh264/res/VID_1920x1080_cabac_temporal_direct.264 -frames:v 1 "$src/photo.png"
[ -f "$src/odd.png" ] || magick "$src/photo.png" -crop 333x171+400+300 +repage "$src/odd.png"
[ -f "$src/small.png" ] || magick "$src/photo.png" -resize 97x55! "$src/small.png"
[ -f "$src/logo.png" ] || magick -background none -density 300 assets/logo.svg "$src/logo.png" 2>/dev/null || rm -f "$src/logo.png"
# An RGBA source with real transparency.
[ -f "$src/alpha.png" ] || magick "$src/odd.png" \( +clone -fx 'i/w' \) -alpha off -compose copy_opacity -composite "$src/alpha.png"
# m name format args...: one ImageMagick output ("" uses the extension's format).
m() { local name=$1 f=$2; shift 2; [ -f "$out/$name" ] || magick "$@" "${f:+$f:}$out/$name"; }

# PNG: every colour type and depth stb_image reads, interlaced too.
m png_rgb8.png "PNG24" "$src/photo.png" -strip
m png_rgba8.png "PNG32" "$src/alpha.png" -strip
m png_gray8.png "" "$src/odd.png" -colorspace Gray -depth 8 -strip -define png:color-type=0
m png_graya8.png "" "$src/alpha.png" -colorspace Gray -depth 8 -strip -define png:color-type=4
m png_pal8.png "PNG8" "$src/odd.png" -colors 200 -strip
m png_pal_trns.png "PNG8" "$src/alpha.png" -channel A -threshold 50% +channel -colors 64 -strip
m png_rgb16.png "PNG48" "$src/odd.png" -depth 16 -strip
m png_rgba16.png "PNG64" "$src/alpha.png" -depth 16 -strip
m png_gray16.png "" "$src/odd.png" -colorspace Gray -depth 16 -strip -define png:color-type=0
m png_interlaced.png "PNG32" "$src/alpha.png" -interlace PNG -strip
m png_gray1.png "" "$src/small.png" -colorspace Gray -threshold 50% -depth 1 -strip -define png:color-type=0
if [ -f "$src/logo.png" ]; then m png_logo.png "" "$src/logo.png"; fi

# JPEG: baseline 4:2:0, 4:2:2 and 4:4:4, grayscale, progressive, restart
# markers, odd sizes, CMYK and YCCK (Adobe).
ppm=$src/photo.ppm odd=$src/odd.ppm
[ -f "$ppm" ] || magick "$src/photo.png" "$ppm"
[ -f "$odd" ] || magick "$src/odd.png" "$odd"
j() { [ -f "$out/$1" ] || cjpeg "${@:3}" -outfile "$out/$1" "$2"; }
j jpeg_420.jpg "$ppm" -quality 85 -sample 2x2
j jpeg_422.jpg "$ppm" -quality 85 -sample 2x1
j jpeg_444.jpg "$ppm" -quality 92 -sample 1x1
j jpeg_440.jpg "$odd" -quality 85 -sample 1x2
j jpeg_gray.jpg "$odd" -quality 85 -grayscale
j jpeg_progressive.jpg "$ppm" -quality 85 -progressive
j jpeg_progressive_444.jpg "$odd" -quality 90 -progressive -sample 1x1
j jpeg_restart.jpg "$ppm" -quality 80 -restart 3
j jpeg_odd_420.jpg "$odd" -quality 85 -sample 2x2
j jpeg_q100.jpg "$odd" -quality 100
j jpeg_small.jpg "$src/small.png" -quality 70 2>/dev/null || cjpeg -quality 70 -outfile "$out/jpeg_small.jpg" <(magick "$src/small.png" ppm:-)
m jpeg_cmyk.jpg "" "$src/odd.png" -colorspace CMYK -quality 90
m jpeg_ycck.jpg "" "$src/odd.png" -colorspace CMYK -quality 90 -define jpeg:colorspace=ycck 2>/dev/null || true
j jpeg_411.jpg "$ppm" -quality 85 -sample 4x1
j jpeg_rgb.jpg "$odd" -quality 90 -rgb
j jpeg_progressive_restart.jpg "$ppm" -quality 85 -progressive -restart 1
j jpeg_arithmetic.jpg "$odd" -quality 85 -arithmetic
j jpeg_optimized_odd.jpg "$odd" -quality 60 -optimize -sample 2x2
# A true CMYK file (Adobe transform 0): ImageMagick writes YCCK, so the
# transform byte (11 bytes into the Adobe segment's data) is set to 0.
if [ ! -f "$out/jpeg_cmyk0.jpg" ]; then
	cp "$out/jpeg_cmyk.jpg" "$out/jpeg_cmyk0.jpg"
	at=$(grep -boa Adobe "$out/jpeg_cmyk0.jpg" | head -1 | cut -d: -f1)
	printf '\x00' | dd of="$out/jpeg_cmyk0.jpg" bs=1 seek=$((at + 11)) conv=notrunc status=none
fi
# libjpeg-turbo's test images (tools/fetch_third_party.sh libjpeg-turbo).
for f in testorig testimgint testimgari testorig12; do
	[ -f "third_party/libjpeg-turbo/testimages/$f.jpg" ] && cp -n "third_party/libjpeg-turbo/testimages/$f.jpg" "$out/jpeg_lj_$f.jpg"
done

# GIF: static, interlaced, transparent, and animations with each disposal.
m gif_static.gif "" "$src/odd.png" -colors 256
m gif_interlaced.gif "" "$src/odd.png" -colors 128 -interlace GIF
m gif_transparent.gif "" "$src/alpha.png" -channel A -threshold 50% +channel -colors 64
for d in none background previous; do
	[ -f "$out/gif_anim_$d.gif" ] || magick -delay 10 -dispose "$d" \
		\( "$src/small.png" -colors 64 \) \( "$src/small.png" -flop -colors 64 \) \
		\( "$src/small.png" -crop 40x30+20+10 -colors 32 \) -loop 0 "$out/gif_anim_$d.gif"
done
[ -f "$out/gif_anim_opt.gif" ] || gifsicle -O3 "$out/gif_anim_none.gif" -o "$out/gif_anim_opt.gif"
# Transparent frames smaller than the screen, each disposal in turn, local
# colour tables and a background index.
if [ ! -f "$out/gif_anim_mixed.gif" ]; then
	for k in 0 1 2 3 4; do
		magick "$src/alpha.png" -crop 120x80+$((k * 40))+$((k * 15)) +repage -channel A -threshold 50% +channel -colors 48 "$src/piece$k.gif"
	done
	gifsicle --loopcount=3 --logical-screen 260x160 --background "#305070" --delay 7 \
		--disposal=background -p 0,0 "$src/piece0.gif" --disposal=previous -p 40,20 "$src/piece1.gif" \
		--disposal=none -p 100,50 "$src/piece2.gif" --disposal=background -p 20,70 "$src/piece3.gif" \
		--disposal=previous -p 130,10 "$src/piece4.gif" --disposal=none -p 50,40 "$src/piece0.gif" -o "$out/gif_anim_mixed.gif"
fi
# The same with a global colour table and background index 5: stb fills
# where the first frame does not reach (byte 11 is the background index).
if [ ! -f "$out/gif_anim_global.gif" ]; then
	gifsicle --colors 64 "$out/gif_anim_mixed.gif" -o "$out/gif_anim_global.gif"
	printf '\x05' | dd of="$out/gif_anim_global.gif" bs=1 seek=11 conv=notrunc status=none
fi

# BMP, TGA, QOI.
m bmp_24.bmp "BMP3" "$src/odd.png" -type TrueColor
m bmp_32.bmp "BMP" "$src/alpha.png" -type TrueColorAlpha
m bmp_8_rle.bmp "BMP3" "$src/odd.png" -colors 200 -type Palette
m bmp_8.bmp "BMP3" "$src/odd.png" -colors 200 -type Palette -compress None
m bmp_4.bmp "BMP3" "$src/odd.png" -colors 16 -type Palette -compress None
m bmp_1.bmp "BMP3" "$src/small.png" -threshold 50% -type Bilevel -compress None
m bmp_565.bmp "BMP" "$src/odd.png" -define bmp:subtype=RGB565
m bmp_4444.bmp "BMP" "$src/alpha.png" -define bmp:subtype=ARGB4444
m bmp_32_rgb.bmp "BMP3" "$src/alpha.png" -type TrueColorAlpha
m tga_24.tga "" "$src/odd.png" -type TrueColor
m tga_32.tga "" "$src/alpha.png" -type TrueColorAlpha
m tga_rle.tga "" "$src/alpha.png" -compress RLE
m qoi_rgba.qoi "" "$src/alpha.png"
m qoi_rgb.qoi "" "$src/odd.png"

# Radiance HDR, linear and brighter than 1: RLE scanlines (widths 8 to
# 32767) from ImageMagick and ffmpeg, flat ones (narrower or wider), and the
# #?RGBE signature. The wide one is ffmpeg's: ImageMagick writes RLE at
# width 32768, past the format's limit, which Radiance and stb read as flat.
m hdr_rle.hdr "" "$src/odd.png" -colorspace RGB -evaluate pow 2 -evaluate multiply 40
m hdr_small.hdr "" "$src/small.png" -colorspace RGB -evaluate multiply 3
m hdr_flat.hdr "" "$src/small.png" -crop 5x40+0+0 +repage -colorspace RGB -evaluate multiply 7
[ -f "$out/hdr_ffmpeg.hdr" ] || ffmpeg -v error -y -i "$src/photo.png" -vf format=gbrpf32le "$out/hdr_ffmpeg.hdr"
[ -f "$out/hdr_wide.hdr" ] || ffmpeg -v error -y -f lavfi -i gradients=s=32768x3:c0=0x200000:c1=0x0000ff:nb_colors=2 -frames:v 1 -vf format=gbrpf32le "$out/hdr_wide.hdr"
[ -f "$out/hdr_rgbe.hdr" ] || sed '1s/^#?RADIANCE$/#?RGBE/' "$out/hdr_small.hdr" > "$out/hdr_rgbe.hdr"

# WebP comes from the WebP gate's corpus; add two.
[ -f "$out/webp_lossy.webp" ] || cp .work/decode-benchmark/inputs/webp-lossy.webp "$out/webp_lossy.webp" 2>/dev/null || true
[ -f "$out/webp_lossless.webp" ] || cp .work/decode-benchmark/inputs/webp-lossless.webp "$out/webp_lossless.webp" 2>/dev/null || true
ls "$out" | grep -v '^src$' | wc -l | tr -d ' '
