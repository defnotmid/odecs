#!/usr/bin/env bash
# Small ProRes (.mov) and VP9 (.webm) fixtures for the alpha-video decoders,
# plus FFmpeg's own decode of each as the comparison oracle. FFmpeg is a
# development oracle only; nothing here runs at decode time.
#
#   tests/alpha_fixtures.sh OUTDIR [--large]
#
# For each NAME.{mov,webm} the script writes NAME.yuv: FFmpeg's decoded
# planes in the stream's native layout (NAME.fmt holds the pix_fmt, e.g.
# yuva444p12le), every frame back to back. --large adds 1080p clips for
# benchmarks.
set -euo pipefail
out=${1:?usage: alpha_fixtures.sh OUTDIR [--large]}
large=${2:-}
mkdir -p "$out"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }

# A moving test pattern whose alpha has hard edges, a soft gradient, a fully
# transparent band and a fully opaque disc, so run-length and literal alpha
# coding both occur.
alpha_src() { # W H FRAMES
	echo "testsrc2=s=$1x$2:r=30,format=yuva444p,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(lt(hypot(X-W/2-W/5*sin(N/3),Y-H/2),H/4),255,if(lt(X,W/8),0,if(lt(Y,H/6),X*255/W,128+127*sin(X/9+Y/7+N))))',trim=end_frame=$3"
}
plain_src() { echo "testsrc2=s=$1x$2:r=30,trim=end_frame=$3"; }

oracle() { # NAME PIX_FMT
	ff -i "$out/$1" -f rawvideo -pix_fmt "$2" "$out/${1%.*}.yuv"
	echo "$2" >"$out/${1%.*}.fmt"
}

# ProRes 422: Proxy, LT, Standard, HQ (prores_ks profiles 0..3).
for p in 0 1 2 3; do
	ff -f lavfi -i "$(plain_src 320 240 8)" -c:v prores_ks -profile:v $p -pix_fmt yuv422p10le "$out/prores_422_p$p.mov"
	oracle prores_422_p$p.mov yuv422p10le
done
# ProRes 4444 / 4444 XQ with 16- and 8-bit alpha, and 4444 without alpha.
ff -f lavfi -i "$(alpha_src 320 240 8)" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le "$out/prores_4444_a16.mov"
oracle prores_4444_a16.mov yuva444p12le
ff -f lavfi -i "$(alpha_src 320 240 8)" -c:v prores_ks -profile:v 4 -alpha_bits 8 -pix_fmt yuva444p10le "$out/prores_4444_a8.mov"
oracle prores_4444_a8.mov yuva444p12le
ff -f lavfi -i "$(alpha_src 320 240 8)" -c:v prores_ks -profile:v 5 -pix_fmt yuva444p10le "$out/prores_4444xq_a16.mov"
oracle prores_4444xq_a16.mov yuva444p12le
ff -f lavfi -i "$(plain_src 320 240 8)" -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le "$out/prores_4444_noalpha.mov"
oracle prores_4444_noalpha.mov yuv444p12le
# Sizes that are not multiples of the 16x16 macroblock, plus interlaced.
ff -f lavfi -i "$(alpha_src 318 238 4)" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le "$out/prores_4444_odd.mov"
oracle prores_4444_odd.mov yuva444p12le
ff -f lavfi -i "$(plain_src 322 242 4)" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$out/prores_422_odd.mov"
oracle prores_422_odd.mov yuv422p10le
ff -f lavfi -i "$(plain_src 320 240 4),setfield=tff" -c:v prores_ks -profile:v 3 -flags +ildct -pix_fmt yuv422p10le "$out/prores_422_interlaced.mov"
oracle prores_422_interlaced.mov yuv422p10le
# QuickTime PCM audio next to ProRes: little-endian 16-bit (sowt), big-endian
# 16-bit (twos), 24-bit (in24) and float (fl32).
for a in pcm_s16le pcm_s16be pcm_s24le pcm_f32le; do
	ff -f lavfi -i "$(plain_src 320 240 30)" -f lavfi -i "sine=f=440:r=48000:d=1" -ac 2 -c:v prores_ks -profile:v 0 -c:a $a -shortest "$out/prores_audio_$a.mov"
done

# VP9 profile 0 without alpha (keyframes every 10 frames, hidden alt-ref
# frames in superframes), with alpha, 4:4:4 (profile 1), 10-bit (profile 2),
# and a 1280x720 clip with four tile columns.
ff -f lavfi -i "$(plain_src 320 240 30)" -c:v libvpx-vp9 -g 10 -auto-alt-ref 1 -lag-in-frames 16 -b:v 300k "$out/vp9_420.webm"
oracle vp9_420.webm yuv420p
ff -f lavfi -i "$(alpha_src 320 240 30)" -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 -g 10 -b:v 300k "$out/vp9_alpha.webm"
ff -c:v libvpx-vp9 -i "$out/vp9_alpha.webm" -f rawvideo -pix_fmt yuva420p "$out/vp9_alpha.yuv" # libvpx reads BlockAdditions
echo yuva420p >"$out/vp9_alpha.fmt"
ff -f lavfi -i "$(plain_src 320 240 12)" -c:v libvpx-vp9 -pix_fmt yuv444p -g 6 -b:v 400k "$out/vp9_444.webm"
oracle vp9_444.webm yuv444p
ff -f lavfi -i "$(plain_src 320 240 12)" -c:v libvpx-vp9 -pix_fmt yuv420p10le -g 6 -b:v 400k "$out/vp9_10bit.webm"
oracle vp9_10bit.webm yuv420p10le
ff -f lavfi -i "$(plain_src 1280 720 12)" -c:v libvpx-vp9 -tile-columns 2 -threads 4 -g 6 -b:v 1M "$out/vp9_tiles.webm"
oracle vp9_tiles.webm yuv420p
ff -f lavfi -i "$(plain_src 318 238 12)" -c:v libvpx-vp9 -g 6 -b:v 300k "$out/vp9_odd.webm"
oracle vp9_odd.webm yuv420p
# Coding tools: lossless (Walsh-Hadamard), cyclic-refresh segmentation,
# error-resilient and frame-parallel modes, tile rows, 12-bit, and fast
# motion with a long alt-ref lag (compound prediction, switchable filters).
ff -f lavfi -i "$(plain_src 320 240 6)" -c:v libvpx-vp9 -lossless 1 "$out/vp9_lossless.webm"
oracle vp9_lossless.webm yuv420p
ff -f lavfi -i "$(plain_src 352 288 20)" -c:v libvpx-vp9 -aq-mode 3 -b:v 200k -g 20 "$out/vp9_segments.webm"
oracle vp9_segments.webm yuv420p
ff -f lavfi -i "$(plain_src 320 240 12)" -c:v libvpx-vp9 -error-resilient 1 -frame-parallel 1 -b:v 300k "$out/vp9_resilient.webm"
oracle vp9_resilient.webm yuv420p
ff -f lavfi -i "$(plain_src 640 480 8)" -c:v libvpx-vp9 -tile-columns 1 -tile-rows 2 -b:v 600k "$out/vp9_tile_rows.webm"
oracle vp9_tile_rows.webm yuv420p
ff -f lavfi -i "$(plain_src 320 240 8)" -c:v libvpx-vp9 -pix_fmt yuv420p12le -b:v 400k "$out/vp9_12bit.webm"
oracle vp9_12bit.webm yuv420p12le
ff -f lavfi -i "mandelbrot=s=320x240:r=30,trim=end_frame=40,format=yuv420p" -c:v libvpx-vp9 -auto-alt-ref 1 -lag-in-frames 25 -arnr-maxframes 7 -b:v 150k -g 40 "$out/vp9_motion.webm"
oracle vp9_motion.webm yuv420p
ff -f lavfi -i "mandelbrot=s=320x240:r=30,trim=end_frame=8,format=gbrp" -c:v libvpx-vp9 -b:v 300k "$out/vp9_rgb.webm" # profile 1 sRGB: planes G, B, R
oracle vp9_rgb.webm gbrp
# Two-pass: libvpx makes alt-ref frames only then, and with them compound
# prediction (reference_mode select) and hidden frames in superframes.
twopass() { # SOURCE OUTPUT ARGS...
	local src=$1 dst=$2
	shift 2
	ff -f lavfi -i "$src" -c:v libvpx-vp9 "$@" -pass 1 -passlogfile "$out/vp9pass" -f null /dev/null
	ff -f lavfi -i "$src" -c:v libvpx-vp9 "$@" -pass 2 -passlogfile "$out/vp9pass" "$dst"
}
twopass "$(plain_src 320 240 40)" "$out/vp9_twopass.webm" -b:v 300k -g 40 -auto-alt-ref 1 -lag-in-frames 25
oracle vp9_twopass.webm yuv420p
# Opus audio in WebM (demuxed and reported; not decoded).
ff -f lavfi -i "$(plain_src 320 240 30)" -f lavfi -i "sine=f=440:r=48000:d=1" -c:v libvpx-vp9 -b:v 200k -c:a libopus -shortest "$out/vp9_opus.webm"

if [[ $large == --large ]]; then
	ff -f lavfi -i "$(alpha_src 1920 1080 60)" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le "$out/prores_4444_1080p.mov"
	ff -f lavfi -i "$(plain_src 1920 1080 60)" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$out/prores_422hq_1080p.mov"
	ff -f lavfi -i "$(alpha_src 1920 1080 120)" -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 -g 30 -b:v 4M -tile-columns 2 -threads 8 "$out/vp9_alpha_1080p.webm"
	twopass "$(plain_src 1920 1080 120)" "$out/vp9_1080p.webm" -g 60 -b:v 4M -tile-columns 2 -threads 8 -auto-alt-ref 1 -lag-in-frames 25
fi
# HEVC with an auxiliary alpha layer needs an x265 built with ENABLE_ALPHA
# (stock packages are not); point X265_ALPHA at one to include it. Raw
# Y, U, V, A planes in, Annex-B out, then MP4. Without B-frames the
# presented frames match FFmpeg's one for one; with them the alpha pairing
# crosses reordering.
if [ -n "${X265_ALPHA:-}" ]; then
	ff -f lavfi -i "$(alpha_src 320 240 30)" -f rawvideo -pix_fmt yuva420p "$out/hevc_alpha.yuva"
	"$X265_ALPHA" --alpha --input "$out/hevc_alpha.yuva" --input-res 320x240 --fps 30 --bframes 0 --log-level error -o "$out/hevc_alpha.hevc"
	"$X265_ALPHA" --alpha --input "$out/hevc_alpha.yuva" --input-res 320x240 --fps 30 --log-level error -o "$out/hevc_alpha_bframes.hevc"
	for name in hevc_alpha hevc_alpha_bframes; do
		ff -framerate 30 -i "$out/$name.hevc" -c copy -tag:v hvc1 "$out/$name.mov"
		ff -i "$out/$name.mov" -fps_mode passthrough -f rawvideo -pix_fmt yuva420p "$out/$name.yuv"
		echo yuva420p > "$out/$name.fmt"
	done
	rm -f "$out/hevc_alpha.yuva"
fi
ls -la "$out"
