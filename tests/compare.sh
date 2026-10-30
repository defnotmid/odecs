#!/usr/bin/env bash
# oicut against the reference implementations: decoding and encoding speed on
# one pinned core, and the encoders' size at equal quality (BD-rate); plus
# the alpha-video and Vulkan Video figures the demo shows. Each
# figure is one row of BENCHMARKS.tsv, replaced when its case runs again;
# BENCHMARKS.md is generated from it and demo/facts.lua reads it.
# Development only: the references are built here from third_party/ at the
# commits in THIRD_PARTY_REFERENCES.md (stb_image is Odin's vendored copy)
# and are never linked into oicut.
#
#   bash tools/fetch_third_party.sh ffmpeg libvpx opus libwebp openh264 libjpeg-turbo libvorbis libogg \
#     x264 x265 dav1d Vulkan-Headers
#   bash tests/opus_fixtures.sh       # the audio source (the RFC 8251 vectors)
#   bash tests/compare.sh build       # references and harnesses
#   bash tests/compare.sh inputs      # inputs, encoded once from pinned material
#   bash tests/compare.sh run [REGEX] # the cases whose id matches; default all but gpu/
#   bash tests/compare.sh doc         # BENCHMARKS.md from BENCHMARKS.tsv (run does this)
#   bash tests/compare.sh list        # the case ids
#
# CPU (default 23) is the measured core; GPU names the GPU for gpu/ rows.
# Run on an otherwise idle machine: each row records the load average.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=${WORK:-.work/compare}
CPU=${CPU:-23}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$WORK"
WORK=$(realpath "$WORK")
REF=$WORK/ref BIN=$WORK/bin IN=$WORK/inputs OUT=$WORK/out
TSV=BENCHMARKS.tsv DOC=BENCHMARKS.md
VECTORS=${VECTORS:-.work/opusfx/vectors/opus_newvectors}
HEADER=$'id\tlabel\toicut\treference\tunit\tratio\tagainst\tdate\trevision\tmachine\tload\tbasis'

FFMPEG="FFmpeg n9.0.2"
LIBVPX="libvpx 1.17.0"
X264="x264 0.165 (b35605a)"
X265="x265 4.2"

build() {
	mkdir -p "$REF/prefix" "$BIN"
	local root=$PWD prefix=$REF/prefix
	if [ ! -f "$prefix/lib/libvpx.a" ]; then
		mkdir -p "$REF/libvpx" && (cd "$REF/libvpx" &&
			"$root/third_party/libvpx/configure" --prefix="$prefix" --disable-examples --disable-tools \
				--disable-docs --disable-unit-tests --disable-vp8 --enable-vp9-highbitdepth --enable-pic >/dev/null &&
			make -s -j"$JOBS" >/dev/null && make -s install >/dev/null)
	fi
	if [ ! -f "$prefix/lib/libopus.a" ]; then
		cmake -S third_party/opus -B "$REF/opus" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
			-DCMAKE_INSTALL_LIBDIR=lib -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF >/dev/null
		cmake --build "$REF/opus" -j"$JOBS" >/dev/null 2>&1 && cmake --install "$REF/opus" >/dev/null
	fi
	if [ ! -f "$prefix/lib/libwebp.a" ]; then
		cmake -S third_party/libwebp -B "$REF/libwebp" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
			-DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
			-DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
			-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF >/dev/null
		cmake --build "$REF/libwebp" -j"$JOBS" >/dev/null && cmake --install "$REF/libwebp" >/dev/null
	fi
	if [ ! -f "$prefix/lib/libturbojpeg.a" ]; then
		cmake -S third_party/libjpeg-turbo -B "$REF/libjpeg-turbo" -DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF \
			-DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib >/dev/null
		cmake --build "$REF/libjpeg-turbo" -j"$JOBS" >/dev/null && cmake --install "$REF/libjpeg-turbo" >/dev/null
	fi
	if [ ! -f "$prefix/lib/libvorbisfile.a" ]; then
		local common=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
			-DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
		cmake -S third_party/libogg -B "$REF/libogg" "${common[@]}" -DINSTALL_DOCS=OFF >/dev/null
		cmake --build "$REF/libogg" -j"$JOBS" >/dev/null && cmake --install "$REF/libogg" >/dev/null
		cmake -S third_party/libvorbis -B "$REF/libvorbis" "${common[@]}" >/dev/null
		cmake --build "$REF/libvorbis" -j"$JOBS" >/dev/null && cmake --install "$REF/libvorbis" >/dev/null
	fi
	if [ ! -f "$prefix/lib/libx264.a" ]; then
		mkdir -p "$REF/x264" && (cd "$REF/x264" &&
			"$root/third_party/x264/configure" --prefix="$prefix" --enable-static --disable-cli --enable-pic >/dev/null &&
			make -s -j"$JOBS" >/dev/null && make -s install >/dev/null)
	fi
	if [ ! -f "$prefix/lib/libx265.a" ]; then
		cmake -S third_party/x265/source -B "$REF/x265" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
			-DCMAKE_INSTALL_LIBDIR=lib -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null
		cmake --build "$REF/x265" -j"$JOBS" >/dev/null && cmake --install "$REF/x265" >/dev/null
	fi
	if [ ! -f "$prefix/lib/libdav1d.a" ]; then
		meson setup "$REF/dav1d" third_party/dav1d --buildtype=release --default-library=static --prefix="$prefix" \
			--libdir=lib -Denable_tools=false -Denable_tests=false >/dev/null
		ninja -C "$REF/dav1d" -j"$JOBS" >/dev/null && ninja -C "$REF/dav1d" install >/dev/null
	fi
	# Rebuilt whenever this configuration changes.
	local ffmpeg_config=(--prefix="$prefix" --pkg-config-flags=--static --disable-everything --disable-programs --disable-doc
		--disable-network --disable-autodetect --enable-static --disable-shared --enable-libvpx --enable-libopus
		--enable-libdav1d --enable-vulkan --extra-cflags="-I$root/third_party/Vulkan-Headers/include"
		--enable-decoder=h264,hevc,vp9,av1,libvpx_vp9,libdav1d,prores,aac,alac,flac,mp3float,opus,libopus
		--enable-hwaccel=h264_vulkan,hevc_vulkan,av1_vulkan --enable-encoder=aac,h264_vulkan,hevc_vulkan
		--enable-demuxer=mov,matroska,ogg,flac,mp3,h264,hevc --enable-parser=h264,hevc,vp9,av1,aac,flac,mpegaudio,opus
		--enable-bsf=vp9_superframe_split --enable-protocol=file)
	if [ ! -f "$prefix/lib/libavcodec.a" ] || [ "$(cat "$REF/ffmpeg.config" 2>/dev/null)" != "${ffmpeg_config[*]}" ]; then
		rm -rf "$REF/ffmpeg" && mkdir -p "$REF/ffmpeg" && (cd "$REF/ffmpeg" &&
			PKG_CONFIG_PATH="$prefix/lib/pkgconfig" "$root/third_party/ffmpeg/configure" "${ffmpeg_config[@]}" >/dev/null &&
			make -s -j"$JOBS" >/dev/null && make -s install >/dev/null)
		echo "${ffmpeg_config[*]}" > "$REF/ffmpeg.config"
	fi
	local pc="env PKG_CONFIG_PATH=$prefix/lib/pkgconfig pkg-config --static"
	# shellcheck disable=SC2046
	c++ -std=c++17 -O3 -Wall -Wextra -Werror tests/reference_decode.cpp \
		$($pc --cflags --libs libavformat libavcodec libavutil) -o "$BIN/reference_decode"
	# shellcheck disable=SC2046
	cc -std=c11 -O3 -Wall -Wextra -Werror tests/reference_webp.c $($pc --cflags --libs libwebp) -o "$BIN/reference_webp"
	# shellcheck disable=SC2046
	cc -std=c11 -O3 -Wall -Wextra -Werror tests/reference_vp9_encode.c $($pc --cflags --libs vpx) -o "$BIN/reference_vp9_encode"
	# shellcheck disable=SC2046
	cc -std=c11 -O3 -Wall -Wextra -Werror tests/reference_vulkan_encode.c $($pc --cflags --libs libavcodec libavutil) \
		-o "$BIN/reference_vulkan_encode"
	# shellcheck disable=SC2046
	cc -std=c11 -O3 -Wall -Wextra tests/reference_audio.c $($pc --cflags --libs libavcodec libavutil) -lm -pthread \
		-o "$BIN/reference_audio"
	# shellcheck disable=SC2046
	c++ -std=c++17 -O3 -Wall -Wextra -Werror tests/reference_video_decode.cpp \
		$($pc --cflags --libs libavformat libavcodec libavutil) -pthread -o "$BIN/reference_streams"
	# shellcheck disable=SC2046
	c++ -std=c++17 -O3 tests/x264_benchmark.cpp $($pc --cflags --libs x264) -o "$BIN/x264"
	# shellcheck disable=SC2046
	c++ -std=c++17 -O3 tests/x265_benchmark.cpp $($pc --cflags --libs x265) -o "$BIN/x265"
	odin_build() { odin build "$1" -file -o:speed -microarch:native -define:OICUT_PATENTED=true "${@:2}"; }
	odin_build tests/decode_benchmark.odin -out:"$BIN/oicut_decode"
	odin_build tests/benchmark.odin -out:"$BIN/oicut_h264"
	odin_build tests/encode_timing_h265.odin -out:"$BIN/oicut_h265"
	odin_build tests/vp9_encode_check.odin -out:"$BIN/oicut_vp9"
	odin_build tests/audio_timing.odin -out:"$BIN/oicut_audio"
	odin_build tests/audio_compare.odin -out:"$BIN/audio_compare"
	odin_build tests/audio_fixture.odin -out:"$BIN/audio_fixture"
	odin_build tests/video_decode_timing.odin -out:"$BIN/oicut_streams"
	odin_build tests/yuv_dump.odin -out:"$BIN/dump_h264"
	odin_build tests/decode_h265.odin -out:"$BIN/dump_h265"
	odin_build tests/bd_rate.odin -out:"$BIN/bd_rate"
	odin_build tests/image_compare.odin -out:"$BIN/image_compare"
	odin_build tests/jpeg_compare.odin -extra-linker-flags:"-L$prefix/lib" -out:"$BIN/jpeg_compare_native"
	odin build tests/jpeg_compare.odin -file -o:speed -microarch:x86-64-v3 -extra-linker-flags:"-L$prefix/lib" -out:"$BIN/jpeg_compare_x86-64-v3"
	odin build tests/jpeg_compare.odin -file -o:speed -extra-linker-flags:"-L$prefix/lib" -out:"$BIN/jpeg_compare_default"
	odin_build tests/vorbis_compare.odin -extra-linker-flags:"-L$prefix/lib" -out:"$BIN/vorbis_compare"
	# The figures onimite sees: its builds are -o:speed for any x86-64.
	odin build tests/movie_alpha.odin -file -o:speed -define:OICUT_PATENTED=true -out:"$BIN/oicut_alpha"
	for depth in 1 3; do
		odin build tests/movie_decode_timing.odin -file -o:speed -define:OICUT_DECODE_DEPTH=$depth -out:"$BIN/gpu_decode$depth"
		odin build tests/movie_encode_timing.odin -file -o:speed -define:OICUT_ENCODE_DEPTH=$depth -out:"$BIN/gpu_encode$depth"
	done
}

inputs() {
	mkdir -p "$IN"
	local ff=(ffmpeg -v error -y) video=$IN/source.y4m audio=$IN/source.wav
	if [ ! -f "$video" ]; then
		"${ff[@]}" -i third_party/openh264/res/VID_1920x1080_cabac_temporal_direct.264 -pix_fmt yuv420p "$IN/fixture.y4m"
		"${ff[@]}" -stream_loop 2 -i "$IN/fixture.y4m" -c copy "$video"
		rm "$IN/fixture.y4m"
	fi
	[ -f "$IN/encode.yuv" ] || "${ff[@]}" -i third_party/openh264/res/VID_1920x1080_cabac_temporal_direct.264 \
		-pix_fmt yuv420p -f rawvideo "$IN/encode.yuv"
	[ -f "$audio" ] || cat "$VECTORS"/testvector??.dec | "${ff[@]}" -f s16le -ar 48000 -ac 2 -i - "$audio"
	# audio_compare measures three equal sections: a whole number of frames per section.
	if [ ! -f "$IN/source.s16le" ]; then
		"${ff[@]}" -i "$audio" -f s16le "$IN/full.s16le"
		head -c $(($(stat -c %s "$IN/full.s16le") / 12 * 12)) "$IN/full.s16le" > "$IN/source.s16le"
		rm "$IN/full.s16le"
	fi
	local v=(-i "$video") a=(-i "$audio")
	enc() { [ -f "$IN/$1" ] || { "${ff[@]}" "${@:2}" "$IN/partial.$1" && mv "$IN/partial.$1" "$IN/$1"; }; }
	enc h264-high.mp4 "${v[@]}" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p
	enc h264-high10.mp4 "${v[@]}" -c:v libx264 -preset medium -crf 20 -profile:v high10 -pix_fmt yuv420p10le
	enc h264-high422.mp4 "${v[@]}" -c:v libx264 -preset medium -crf 20 -profile:v high422 -pix_fmt yuv422p10le
	enc hevc-main.mp4 "${v[@]}" -c:v libx265 -preset medium -crf 24 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error
	enc hevc-main10.mp4 "${v[@]}" -c:v libx265 -preset medium -crf 24 -pix_fmt yuv420p10le -tag:v hvc1 -x265-params log-level=error
	enc vp9-p0.webm "${v[@]}" -c:v libvpx-vp9 -crf 32 -b:v 0 -cpu-used 2 -row-mt 0 -pix_fmt yuv420p
	enc vp9-p2.webm "${v[@]}" -c:v libvpx-vp9 -crf 32 -b:v 0 -cpu-used 2 -row-mt 0 -pix_fmt yuv420p10le
	enc prores-hq.mov "${v[@]}" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le
	enc prores-4444.mov "${v[@]}" -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le
	enc av1-720p10.mp4 "${v[@]}" -vf scale=1280:720 -pix_fmt yuv420p10le -c:v libsvtav1 -preset 8 -crf 30
	enc aac-lc.m4a "${a[@]}" -c:a aac -b:a 128k
	enc alac.m4a "${a[@]}" -c:a alac
	enc flac.flac "${a[@]}" -c:a flac -compression_level 5
	enc flac-24-96.flac "${a[@]}" -af aresample=96000 -sample_fmt s32 -bits_per_raw_sample 24 -c:a flac -compression_level 8
	enc mp3.mp3 "${a[@]}" -c:a libmp3lame -b:a 192k
	enc opus.opus "${a[@]}" -c:a libopus -b:a 128k
	enc opus-voip16.opus "${a[@]}" -c:a libopus -application voip -b:a 16k -ac 1
	enc opus-voip32.opus "${a[@]}" -c:a libopus -application voip -b:a 32k
	enc vorbis.ogg "${a[@]}" -c:a libvorbis -q:a 5
	enc webp-lossy.webp -i "$video" -frames:v 1 -c:v libwebp -quality 75
	enc webp-lossless.webp -i "$video" -frames:v 1 -c:v libwebp -lossless 1
	# Images: tests/image_fixtures.sh's, plus a 1080p GIF, RGBA PNG and RLE HDR from its frame.
	[ -f "$IN/image/jpeg_progressive.jpg" ] || bash tests/image_fixtures.sh "$IN/image"
	local photo=$IN/image/src/photo.png
	[ -f "$IN/image/gif-1080p.gif" ] || magick "$photo" -colors 256 "$IN/image/gif-1080p.gif"
	[ -f "$IN/image/png-rgba8-1080p.png" ] || magick "$photo" \( +clone -fx 'i/w' \) -alpha off \
		-compose copy_opacity -composite -strip "PNG32:$IN/image/png-rgba8-1080p.png"
	[ -f "$IN/image/hdr-rle-1080p.hdr" ] || magick "$photo" -colorspace RGB -evaluate pow 2 -evaluate multiply 40 \
		"$IN/image/hdr-rle-1080p.hdr"
	enc h264-high.264 -i "$IN/h264-high.mp4" -c copy -bsf:v h264_mp4toannexb -f h264
	enc hevc-main.265 -i "$IN/hevc-main.mp4" -c copy -bsf:v hevc_mp4toannexb -f hevc
	[ -d .work/webpfx/testdata ] || bash tests/webp_fixtures.sh
	[ -f "$IN/alpha/vp9_1080p.webm" ] || bash tests/alpha_fixtures.sh "$IN/alpha" --large
	[ -f demo/media/transparent.mov ] || sh demo/fetch.sh
	sha256sum "$IN"/*.* > "$IN/inputs.sha256"
}

# Rows ---------------------------------------------------------------------

revision() {
	local base delta
	base=$(jj --no-pager log -r @- --no-graph -T 'commit_id.short(8)' 2>/dev/null || git rev-parse --short=8 HEAD)
	delta=$(jj --no-pager diff -r @ --git '~root-glob:"BENCHMARKS.*"' 2>/dev/null || true)
	if [ -n "$delta" ]; then echo "$base+$(printf '%s' "$delta" | sha256sum | cut -c1-6)"; else echo "$base"; fi
}

# record ID LABEL OICUT REFERENCE UNIT AGAINST [BASIS]: one row, replacing the
# row with the same id. The ratio is oicut's cost against the reference:
# above 1, oicut is slower (time) or larger (size). BASIS is what the time
# covers, for the multiple of real time: seconds of media for a time ("320s"),
# or the clip's frame rate for frames per second or ms per frame ("25fps").
record() {
	local ratio="" machine=$MACHINE row
	if [ -z "$3" ] || { [ -n "$6" ] && [ "$5" != "% BD-rate" ] && [ -z "$4" ]; }; then
		echo "$1: a value was not measured (oicut '$3', reference '$4')" >&2
		exit 1
	fi
	case $5 in
	ms | ms/frame | bytes) [ -n "$4" ] && ratio=$(awk -v a="$3" -v b="$4" 'BEGIN {printf "%.2f", a / b}') ;;
	fps) [ -n "$4" ] && ratio=$(awk -v a="$3" -v b="$4" 'BEGIN {printf "%.2f", b / a}') ;;
	esac
	[[ $1 == gpu/* ]] && machine="$GPU_NAME, $MACHINE"
	row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$ratio" "$6" \
		"$(date +%F)" "$REVISION" "$machine" "$(cut -d' ' -f1 /proc/loadavg)" "${7:-}")
	[ -s "$TSV" ] || echo "$HEADER" > "$TSV"
	awk -F'\t' -v id="$1" -v row="$row" '$1 == id {print row; done = 1; next} {print} END {if (!done) print row}' \
		"$TSV" > "$TSV.new"
	mv "$TSV.new" "$TSV"
	echo "$1" >> "$WORK/recorded"
	printf '%-34s %12s %12s %-9s %6s  %s\n' "$1" "$3" "$4" "$5" "$ratio" "$6"
}

field() { sed -n "s/^\(.*[ :]\)\{0,1\}$1=\([^ ]*\).*/\2/p"; }
median() { sort -g | awk '{v[NR] = $1} END {print NR % 2 ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2}'; }
pinned() { taskset -c "$CPU" "$@"; }
duration() { echo "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")s"; }
plural() { if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 ${2}s"; fi; }

# psnr SOURCE.yuv W H FRAMES DECODED.yuv: FFmpeg's sample-weighted Y, U, V PSNR.
psnr() {
	ffmpeg -hide_banner -f rawvideo -pix_fmt yuv420p -s "$2x$3" -i "$1" -f rawvideo -pix_fmt yuv420p -s "$2x$3" -i "$5" \
		-frames:v "$4" -lavfi psnr -f null - 2>&1 | sed -n 's/.*PSNR .* average:\([0-9.]*\).*/\1/p'
}

# Decoding -----------------------------------------------------------------

# id file kind label reference (decoder name for reference_decode, if not
# FFmpeg's) (threads, if not one pinned core)
DECODE=(
	"h264-high|h264-high.mp4|video|H.264 High, 8-bit, 1080p, 162 frames|$FFMPEG h264|"
	"h264-high10|h264-high10.mp4|video|H.264 High 10, 4:2:0|$FFMPEG h264|"
	"h264-high422|h264-high422.mp4|video|H.264 High 4:2:2, 10-bit|$FFMPEG h264|"
	"hevc-main|hevc-main.mp4|video|HEVC Main, 1080p|$FFMPEG hevc|"
	"hevc-main10|hevc-main10.mp4|video|HEVC Main 10|$FFMPEG hevc|"
	"vp9-p0|vp9-p0.webm|video|VP9 profile 0, 1080p|$FFMPEG vp9|"
	"vp9-p0-libvpx|vp9-p0.webm|video|VP9 profile 0, 1080p|$LIBVPX|libvpx-vp9"
	"vp9-p2|vp9-p2.webm|video|VP9 profile 2, 10-bit|$FFMPEG vp9|"
	"vp9-p2-libvpx|vp9-p2.webm|video|VP9 profile 2, 10-bit|$LIBVPX|libvpx-vp9"
	"prores-422hq|prores-hq.mov|video|ProRes 422 HQ, 1080p|$FFMPEG prores|"
	"prores-4444|prores-4444.mov|video|ProRes 4444, 10-bit|$FFMPEG prores|"
	"prores-422hq-16t|prores-hq.mov|video|ProRes 422 HQ, 1080p, 16 threads|$FFMPEG prores||16"
	"prores-4444-16t|prores-4444.mov|video|ProRes 4444, 10-bit, 16 threads|$FFMPEG prores||16"
	"aac|aac-lc.m4a|audio|AAC-LC, 128 kb/s stereo, 320 s|$FFMPEG aac|"
	"alac|alac.m4a|audio|ALAC, 16-bit stereo|$FFMPEG alac|"
	"flac|flac.flac|audio|FLAC, 16-bit stereo, level 5|$FFMPEG flac|"
	"flac-24-96|flac-24-96.flac|audio|FLAC, 24-bit 96 kHz stereo, level 8|$FFMPEG flac|"
	"mp3|mp3.mp3|audio|MP3, 192 kb/s stereo|$FFMPEG mp3float|"
	"opus|opus.opus|audio|Opus, 128 kb/s stereo|$FFMPEG opus|"
	"opus-libopus|opus.opus|audio|Opus, 128 kb/s stereo|libopus 1.6.1|libopus"
	"opus-voip16|opus-voip16.opus|audio|Opus speech (libopus voip), 16 kb/s mono|$FFMPEG opus|"
	"opus-voip16-libopus|opus-voip16.opus|audio|Opus speech (libopus voip), 16 kb/s mono|libopus 1.6.1|libopus"
	"opus-voip32|opus-voip32.opus|audio|Opus speech (libopus voip), 32 kb/s stereo|$FFMPEG opus|"
	"opus-voip32-libopus|opus-voip32.opus|audio|Opus speech (libopus voip), 32 kb/s stereo|libopus 1.6.1|libopus"
	"webp-lossy|webp-lossy.webp|image|WebP lossy, 1920×1080|libwebp 1.6.0|"
	"webp-lossless|webp-lossless.webp|image|WebP lossless, 1920×1080|libwebp 1.6.0|"
	"webp-bryce|bryce.webp|image|WebP lossy, 11158×2156 (the corpus's bryce.webp, also the demo's)|libwebp 1.6.0|"
)

decode_one() { # id file kind label against decoder threads
	local path=$IN/$2 ours theirs on=(pinned) basis=""
	[ "$2" = bryce.webp ] && path=.work/webpfx/testdata/bryce.webp
	[ -n "$7" ] && on=(env THREADS="$7")
	[ "$3" != image ] && basis=$(duration "$path")
	ours=$("${on[@]}" "$BIN/oicut_decode" "$path" "$3")
	if [ "$3" = image ]; then
		theirs=$("${on[@]}" "$BIN/reference_webp" "$path")
	else
		theirs=$("${on[@]}" "$BIN/reference_decode" "$path" "$3" ${6:+"$6"})
	fi
	# FFmpeg trims the audio encoders' delay and padding; oicut leaves that to the caller.
	awk -v a="$(echo "$ours" | sed -n 's/.* \(frames\|samples\|pixels\)=\([0-9]*\).*/\2/p')" \
		-v b="$(echo "$theirs" | sed -n 's/.* \(frames\|samples\|pixels\)=\([0-9]*\).*/\2/p')" \
		'BEGIN {d = a - b; exit !(b > 0 && (d < 0 ? -d : d) <= b / 1000)}' || { echo "$1: unit counts differ" >&2; return 1; }
	record "decode/$1" "$4" "$(echo "$ours" | field codec_ms)" "$(echo "$theirs" | field codec_ms)" ms "$5" "$basis"
}

# The WebP corpus, every file pinned to the core, medians summed by kind.
decode_webp_corpus() {
	local f kind off tag size a b
	declare -A ours theirs count
	for f in .work/webpfx/testdata/*.webp; do
		off=12 kind=""
		while [ -z "$kind" ]; do
			tag=$(dd if="$f" bs=1 skip=$off count=4 status=none)
			case $tag in "VP8 ") kind=lossy ;; VP8L) kind=lossless ;; "") kind=none ;; esac
			size=$(od -An -tu4 -j $((off + 4)) -N4 "$f" | tr -d ' ')
			off=$((off + 8 + size + (size & 1)))
		done
		a=$(pinned "$BIN/oicut_decode" "$f" image | field codec_ms)
		b=$(pinned "$BIN/reference_webp" "$f" | field codec_ms)
		ours[$kind]=$(awk -v s="${ours[$kind]:-0}" -v v="$a" 'BEGIN {print s + v}')
		theirs[$kind]=$(awk -v s="${theirs[$kind]:-0}" -v v="$b" 'BEGIN {print s + v}')
		count[$kind]=$((${count[$kind]:-0} + 1))
	done
	for kind in lossless lossy; do
		[ -n "${count[$kind]:-}" ] || continue
		record "decode/webp-corpus-$kind" "WebP corpus, its ${count[$kind]} $kind files (libwebp-test-data), summed" \
			"${ours[$kind]}" "${theirs[$kind]}" ms "libwebp 1.6.0"
	done
}

# tests/image_fixtures.sh's 1080p JPEGs (cjpeg from a frame of OpenH264's
# fixture) against libjpeg-turbo with its SIMD, oicut built for this machine,
# for x86-64-v3 (AVX2) and for any x86-64; the best of several decodes.
decode_jpeg() {
	local spec file id label target line suffix
	for spec in "jpeg_420.jpg|jpeg-420|JPEG baseline 4:2:0, quality 85" "jpeg_444.jpg|jpeg-444|JPEG baseline 4:4:4, quality 92" \
		"jpeg_progressive.jpg|jpeg-progressive|JPEG progressive 4:2:0, quality 85"; do
		IFS='|' read -r file id label <<<"$spec"
		for target in native x86-64-v3 default; do
			line=$(pinned "$BIN/jpeg_compare_$target" "$IN/image/$file" | grep "^${file%.jpg}")
			if [[ $line == *FAIL* ]]; then echo "$line" >&2; return 1; fi
			suffix="" && [ $target != native ] && suffix=/$target
			record "decode/$id$suffix" "$label, 1920×1080$([ $target != native ] && echo ", oicut built for $target")" \
				"$(echo "$line" | sed -n 's/.*; \([0-9.]*\) ms (turbo.*/\1/p')" \
				"$(echo "$line" | sed -n 's/.*(turbo \([0-9.]*\),.*/\1/p')" ms "libjpeg-turbo 3.1.2"
		done
	done
}

# oicut/image against stb_image 2.27 (Odin's vendor:stb), which it replaced
# suite-wide: the same files through both, the best of five each; lossless
# formats must be identical (tests/image_compare.odin).
STB=(
	"png_rgb8.png|png-rgb8|PNG, 8-bit RGB, 1920×1080"
	"png-rgba8-1080p.png|png-rgba8|PNG, 8-bit RGBA, 1920×1080"
	"gif-1080p.gif|gif|GIF, 256 colours, 1920×1080"
	"jpeg_420.jpg|jpeg-420|JPEG baseline 4:2:0, 1920×1080"
	"jpeg_progressive.jpg|jpeg-progressive|JPEG progressive 4:2:0, 1920×1080"
	"hdr_ffmpeg.hdr|hdr-ffmpeg|Radiance HDR, RLE scanlines (FFmpeg), 1920×1080"
	"hdr-rle-1080p.hdr|hdr-imagemagick|Radiance HDR, RLE scanlines (ImageMagick), 1920×1080"
	"hdr_wide.hdr|hdr-wide|Radiance HDR, flat 32768×3 scanlines (FFmpeg)"
)

decode_stb() {
	local spec file id label line
	for spec in "${STB[@]}"; do
		IFS='|' read -r file id label <<<"$spec"
		line=$(pinned "$BIN/image_compare" "$IN/image/$file" | grep "^${file%.*}")
		if [[ $line == *FAIL* ]]; then echo "$line" >&2; return 1; fi
		record "decode/stb/$id" "$label" "$(echo "$line" | sed -n 's/.*; \([0-9.]*\) ms (stb.*/\1/p')" \
			"$(echo "$line" | sed -n 's/.*(stb \([0-9.]*\)).*/\1/p')" ms "stb_image 2.27 (Odin vendor:stb)"
	done
}

decode_vorbis() {
	local line
	line=$(pinned "$BIN/vorbis_compare" "$IN/vorbis.ogg" | grep '^vorbis')
	[[ $line == *FAIL* ]] && { echo "$line" >&2; return 1; }
	record decode/vorbis "Vorbis, quality 5 stereo, 320 s (best of several)" \
		"$(echo "$line" | sed -n 's/.*; \([0-9.]*\) ms (libvorbis.*/\1/p')" \
		"$(echo "$line" | sed -n 's/.*(libvorbis \([0-9.]*\)).*/\1/p')" ms "libvorbis 1.3.7" "$(duration "$IN/vorbis.ogg")"
}

# Independent streams of one decoder thread each on fixed CPU slots (an
# editor decoding several clips at once), against FFmpeg the same way. Every
# stream's pictures are hashed outside the timers and must agree.
SLOTS=${SLOTS:-23,0,6,1,7,2,8,3,9,4,10,5,12,18,13,19}
decode_streams() { # codec file label reference-decoder
	local n cpus ours theirs slots
	IFS=, read -r -a slots <<<"$SLOTS"
	for n in 1 12 16; do
		cpus=$(IFS=,; echo "${slots[*]:0:$n}")
		ours=$(VIDEO_CPUS="$cpus" "$BIN/oicut_streams" "$IN/$2" "$1" 1920 1080 162 "$n")
		theirs=$(VIDEO_CPUS="$cpus" "$BIN/reference_streams" "$IN/$2" 162 "$n")
		if [ "$(echo "$ours" | field verification_hash)" != "$(echo "$theirs" | field verification_hash)" ]; then
			echo "decode/streams-$1: oicut and FFmpeg pictures differ" >&2
			return 1
		fi
		record "decode/streams-$1/$n" "$3, $(plural "$n" stream) of one decoder thread each" \
			"$(echo "$ours" | field aggregate_fps)" "$(echo "$theirs" | field aggregate_fps)" fps "$FFMPEG $4" "${CLIP_FPS}fps"
	done
}

# Encoding -----------------------------------------------------------------

W=1920 H=1080 FRAMES=54
CLIP_FPS=25 # OpenH264's 1080p fixture, which every video input comes from

# check_stream CODEC STREAM: FFmpeg and our decoder agree; its PSNR.
check_stream() {
	ffmpeg -v error -y -i "$2" -pix_fmt yuv420p -f rawvideo "$2.ff.yuv"
	"$BIN/dump_$1" "$2" "$2.native.yuv" > "$2.dump.log" 2>&1
	cmp "$2.ff.yuv" "$2.native.yuv"
	[ "$(stat -c %s "$2.ff.yuv")" = "$((W * H * 3 / 2 * FRAMES))" ]
	psnr "$IN/encode.yuv" $W $H $FRAMES "$2.ff.yuv"
}

# encode_point CODEC ENC QP [timed]: one stream of the 54 frames at QP, ours
# (oicut) or the reference's (x); timed runs pinned with every round, the
# others once (ROUNDS=1). Writes its harness line and BYTES:PSNR beside it.
encode_point() {
	local codec=$1 enc=$2 qp=$3 out=$OUT/$1-$2-$3.$1 log on=(env ROUNDS=1)
	[ "${4:-}" = timed ] && on=(taskset -c "$CPU")
	case $codec-$enc in
	h264-oicut) log=$("${on[@]}" "$BIN/oicut_h264" "$IN/encode.yuv" $W $H $FRAMES 1 4 "$qp" "$out") ;;
	h264-x) log=$("${on[@]}" "$BIN/x264" "$IN/encode.yuv" $W $H $FRAMES 1 4 "$qp" "$out") ;;
	h265-oicut) log=$("${on[@]}" "$BIN/oicut_h265" "$IN/encode.yuv" $W $H $FRAMES --qp "$qp" --workers 1 --out "$out") ;;
	h265-x) log=$("${on[@]}" "$BIN/x265" "$IN/encode.yuv" $W $H $FRAMES "$qp" "$out" --pool-threads 1 --no-wpp) ;;
	esac
	echo "$log" > "$out.log"
	echo "$(echo "$log" | field bytes):$(check_stream "$codec" "$out")" > "$out.point"
}

# wait_all PID...: every background job, failing if any did.
wait_all() { local pid; for pid in "$@"; do wait "$pid"; done; }

# encode_sweep NAME: QP 22, 32 and 37 through ours and the reference in
# parallel, untimed; then QP 27 pinned to one core with nothing else running,
# for the speed; the BD-rate over all four.
encode_sweep() {
	local codec=$1 qp enc pids=() ours="" theirs="" against label
	mkdir -p "$OUT"
	for qp in 22 32 37; do
		for enc in oicut x; do
			encode_point "$codec" $enc $qp &
			pids+=($!)
		done
	done
	wait_all "${pids[@]}"
	encode_point "$codec" oicut 27 timed
	encode_point "$codec" x 27 timed
	for qp in 22 27 32 37; do
		ours+=${ours:+,}$(cat "$OUT/$codec-oicut-$qp.$codec.point")
		theirs+=${theirs:+,}$(cat "$OUT/$codec-x-$qp.$codec.point")
	done
	if [ "$codec" = h264 ]; then
		against="$X264, medium with the same tools"
		label="H.264, 1080p, 54 frames, one core, 4 slices (x264: baseline profile, one reference, a keyframe every 15)"
	else
		against="$X265, medium with the same tools"
		label="H.265, 1080p, 54 frames, one core (x265: P frames only, one reference, 64 to 8 CUs, no AMP or rectangular)"
	fi
	record "encode/$codec/speed" "$label, QP 27" "$(field fps < "$OUT/$codec-oicut-27.$codec.log")" \
		"$(field fps < "$OUT/$codec-x-27.$codec.log")" fps "$against" "${CLIP_FPS}fps"
	record "encode/$codec/bd-rate" "$label, QP 22 to 37" "$("$BIN/bd_rate" "$ours" "$theirs" | field bd_rate)" "" "% BD-rate" "$against"
}

encode_h264() { encode_sweep h264; }
encode_h265() { encode_sweep h265; }

# The demo's chart: 16 slices on 16 workers, unpinned.
encode_h264_16() {
	local ours theirs
	mkdir -p "$OUT"
	ours=$("$BIN/oicut_h264" "$IN/encode.yuv" $W $H $FRAMES 16 16 27 "$OUT/h264-16.264")
	theirs=$("$BIN/x264" "$IN/encode.yuv" $W $H $FRAMES 16 16 27 "$OUT/x264-16.264")
	check_stream h264 "$OUT/h264-16.264" > /dev/null
	record encode/h264-16/speed "H.264, 1080p, 54 frames, 16 slices on 16 workers, QP 27" \
		"$(echo "$ours" | field fps)" "$(echo "$theirs" | field fps)" fps "$X264, medium with the same tools" "${CLIP_FPS}fps"
}

# Ours at q 60 to 180 against libvpx at cq-level 15 to 45, one core, one
# keyframe, all eight encodes in parallel and untimed; then the speed, pinned
# with nothing else running: ours at q 100 (seven runs) against cq-level 25
# (about the same quantizer).
vp9_point() { # oicut|libvpx q|cq: writes BYTES:PSNR to $OUT/vp9-<enc>-<q>.point
	local log out=$OUT/vp9-$1-$2
	if [ "$1" = oicut ]; then
		log=$("$BIN/oicut_vp9" "$out" $W $H "$2" 1 $FRAMES 0 "$IN/encode.yuv" 0 120)
		ffmpeg -v error -y -i "$out.webm" -pix_fmt yuv420p -f rawvideo "$out.yuv"
	else
		log=$(ROUNDS=1 "$BIN/reference_vp9_encode" "$IN/encode.yuv" $W $H $FRAMES "$2" 120 "$out.ivf")
		ffmpeg -v error -y -i "$out.ivf" -pix_fmt yuv420p -f rawvideo "$out.yuv"
	fi
	echo "$(echo "$log" | field bytes):$(psnr "$IN/encode.yuv" $W $H $FRAMES "$out.yuv")" > "$out.point"
}

encode_vp9() {
	local q cq pids=() ours="" theirs="" runs=() i
	mkdir -p "$OUT"
	for q in 60 100 140 180; do vp9_point oicut $q & pids+=($!); done
	for cq in 15 25 35 45; do vp9_point libvpx $cq & pids+=($!); done
	wait_all "${pids[@]}"
	for q in 60 100 140 180; do ours+=${ours:+,}$(cat "$OUT/vp9-oicut-$q.point"); done
	for cq in 15 25 35 45; do theirs+=${theirs:+,}$(cat "$OUT/vp9-libvpx-$cq.point"); done
	for i in 1 2 3 4 5 6 7; do
		runs+=("$(pinned "$BIN/oicut_vp9" - $W $H 100 1 $FRAMES 0 "$IN/encode.yuv" 0 120 | field fps)")
	done
	local label="VP9, 1080p, 54 frames, one core, four tile columns (libvpx: good, cpu-used 4, no lag or alt-ref)"
	record encode/vp9/speed "$label, q 100 against cq-level 25" "$(printf '%s\n' "${runs[@]}" | median)" \
		"$(pinned "$BIN/reference_vp9_encode" "$IN/encode.yuv" $W $H $FRAMES 25 120 "$OUT/vp9-libvpx-timed.ivf" | field fps)" fps "$LIBVPX" "${CLIP_FPS}fps"
	record encode/vp9/bd-rate "$label, q 60 to 180 against cq-level 15 to 45" \
		"$("$BIN/bd_rate" "$ours" "$theirs" | field bd_rate)" "" "% BD-rate" "$LIBVPX"
}

# 320 s of music at 192 kb/s, one stream on one core; SNR after FFmpeg's
# decoder, aligned by the 1024-sample priming.
encode_aac() {
	local ours theirs snr=()
	mkdir -p "$OUT"
	ours=$(pinned "$BIN/oicut_audio" encode "$IN/source.s16le" 48000 2 192000 1 "$OUT/aac-oicut.aac")
	theirs=$(pinned "$BIN/reference_audio" encode "$IN/source.s16le" 48000 2 192000 1 "$OUT/aac-ffmpeg.aac")
	for enc in oicut ffmpeg; do
		"$BIN/reference_audio" decode "$OUT/aac-$enc.aac" 1 "$OUT/aac-$enc.s16le" > /dev/null
		snr+=("$("$BIN/audio_compare" quality "$IN/source.s16le" "$OUT/aac-$enc.s16le" 48000 2 1024 |
			grep -m1 'section=overall' | field snr_db)")
	done
	local label="AAC-LC, 48 kHz stereo, 192 kb/s, 320 s"
	record encode/aac/speed "$label, one stream" "$(echo "$ours" | grep -m1 codec_ms= | field codec_ms)" \
		"$(echo "$theirs" | grep -m1 'aggregate' | field codec_ms)" ms "$FFMPEG aac" "$(awk -v b="$(stat -c %s "$IN/source.s16le")" 'BEGIN {printf "%.4f", b / 192000}')s"
	record encode/aac/snr "$label, SNR after FFmpeg's decoder" "${snr[0]}" "${snr[1]}" dB "$FFMPEG aac"
}

# tests/audio_fixture.odin's 12 s signal (a tone and chirp, transients, then
# noise, a third each): one stream on one core, and 16 independent streams,
# which must equal the one; SNR per third after FFmpeg's decoder.
MULTI_CPUS=${MULTI_CPUS:-0-23}
encode_aac_fixture() {
	local spec rate ch bits id kind src enc n ours theirs label section
	mkdir -p "$OUT"
	for spec in "44100|1|64000|44k-mono|44.1 kHz mono, 64 kb/s" "48000|2|128000|48k-stereo|48 kHz stereo, 128 kb/s"; do
		IFS='|' read -r rate ch bits id kind <<<"$spec"
		src=$OUT/aac-fixture-$id.s16le
		"$BIN/audio_fixture" "$src" "$rate" "$ch" 12 > /dev/null
		label="AAC-LC, the 12 s fixture, $kind"
		for n in 1 16; do
			if [ "$n" = 1 ]; then
				ours=$(pinned "$BIN/oicut_audio" encode "$src" "$rate" "$ch" "$bits" 1 "$OUT/aac-$id-oicut.aac")
				theirs=$(pinned "$BIN/reference_audio" encode "$src" "$rate" "$ch" "$bits" 1 "$OUT/aac-$id-ffmpeg.aac")
				record "encode/aac-fixture/$id/speed" "$label, one stream" "$(echo "$ours" | grep -m1 codec_ms= | field codec_ms)" \
					"$(echo "$theirs" | grep -m1 aggregate | field codec_ms)" ms "$FFMPEG aac" 12s
			else
				ours=$(taskset -c "$MULTI_CPUS" "$BIN/oicut_audio" encode "$src" "$rate" "$ch" "$bits" 16 "$OUT/aac-$id-oicut-16.aac")
				theirs=$(taskset -c "$MULTI_CPUS" "$BIN/reference_audio" encode "$src" "$rate" "$ch" "$bits" 16 "$OUT/aac-$id-ffmpeg-16.aac")
				cmp "$OUT/aac-$id-oicut.aac" "$OUT/aac-$id-oicut-16.aac"
				cmp "$OUT/aac-$id-ffmpeg.aac" "$OUT/aac-$id-ffmpeg-16.aac"
				record "encode/aac-fixture/$id/speed-16" "$label, 16 independent streams" "$(echo "$ours" | grep -m1 codec_ms= | field codec_ms)" \
					"$(echo "$theirs" | grep -m1 aggregate | field codec_ms)" ms "$FFMPEG aac" 192s
			fi
		done
		for enc in oicut ffmpeg; do
			"$BIN/reference_audio" decode "$OUT/aac-$id-$enc.aac" 1 "$OUT/aac-$id-$enc.s16le" > /dev/null
			"$BIN/audio_compare" quality "$src" "$OUT/aac-$id-$enc.s16le" "$rate" "$ch" 1024 > "$OUT/aac-$id-$enc.quality"
		done
		for section in tone_chirp transient noise; do
			record "encode/aac-fixture/$id/snr-$section" "$label, SNR of the ${section/_/ and } third after FFmpeg's decoder" \
				"$(grep "section=$section " "$OUT/aac-$id-oicut.quality" | field snr_db)" \
				"$(grep "section=$section " "$OUT/aac-$id-ffmpeg.quality" | field snr_db)" dB "$FFMPEG aac"
		done
	done
}

# The 320x180 synthetic animation of tests/vp9_encode_check.odin, 30 frames,
# one keyframe: ours at q 60 to 180 against libvpx at cq-level 36 to 60, and
# both lossless (libvpx's output must equal the source).
encode_vp9_animation() {
	local i q cq ours="" theirs="" log out src=$OUT/vp9-anim-oicut-60.source.yuv w=320 h=180 n=30 lossless_ours
	local qs=(60 100 140 180) cqs=(36 44 52 60)
	mkdir -p "$OUT"
	for i in 0 1 2 3; do
		q=${qs[$i]} cq=${cqs[$i]}
		log=$(pinned "$BIN/oicut_vp9" "$OUT/vp9-anim-oicut-$q" $w $h "$q" 1 $n 0 animation 0 120)
		ffmpeg -v error -y -i "$OUT/vp9-anim-oicut-$q.webm" -pix_fmt yuv420p -f rawvideo "$OUT/vp9-anim-oicut-$q.yuv"
		ours+=${ours:+,}$(echo "$log" | field bytes):$(psnr "$src" $w $h $n "$OUT/vp9-anim-oicut-$q.yuv")
		out=$OUT/vp9-anim-libvpx-$cq.ivf
		log=$(ROUNDS=1 "$BIN/reference_vp9_encode" "$src" $w $h $n "$cq" 120 "$out")
		ffmpeg -v error -y -i "$out" -pix_fmt yuv420p -f rawvideo "$out.yuv"
		theirs+=${theirs:+,}$(echo "$log" | field bytes):$(psnr "$src" $w $h $n "$out.yuv")
	done
	lossless_ours=$(pinned "$BIN/oicut_vp9" "$OUT/vp9-anim-oicut-0" $w $h 0 1 $n 0 animation 0 120 | field bytes)
	log=$(ROUNDS=1 "$BIN/reference_vp9_encode" "$src" $w $h $n lossless 120 "$OUT/vp9-anim-libvpx-lossless.ivf")
	ffmpeg -v error -y -i "$OUT/vp9-anim-libvpx-lossless.ivf" -pix_fmt yuv420p -f rawvideo "$OUT/vp9-anim-libvpx-lossless.yuv"
	cmp "$src" "$OUT/vp9-anim-libvpx-lossless.yuv"
	local label="VP9, a 320x180 synthetic animation (gradient, moving rectangle, text-like strokes), 30 frames, one core"
	record encode/vp9-animation/bd-rate "$label, q 60 to 180 against cq-level 36 to 60" \
		"$("$BIN/bd_rate" "$ours" "$theirs" | field bd_rate)" "" "% BD-rate" "$LIBVPX"
	record encode/vp9-animation/lossless "$label, lossless" "$lossless_ours" "$(echo "$log" | field bytes)" bytes "$LIBVPX"
}

# Our VP9 encoder alone at 1080p on the synthetic animation, one worker and
# four (one per tile column), unpinned; the best of three after a warmup.
encode_vp9_workers() {
	local spec q frames alpha id kind workers r best fps
	for spec in "100|16|0|q100|q 100 colour, 16 frames" "0|8|1|lossless-alpha|lossless colour and alpha, 8 frames"; do
		IFS='|' read -r q frames alpha id kind <<<"$spec"
		for workers in 1 4; do
			"$BIN/oicut_vp9" - $W $H 100 "$workers" 4 0 animation 0 120 > /dev/null
			best=0
			for r in 1 2 3; do
				fps=$("$BIN/oicut_vp9" - $W $H "$q" "$workers" "$frames" "$alpha" animation 0 120 | field fps)
				best=$(awk -v a="$best" -v b="$fps" 'BEGIN {print (b > a ? b : a)}')
			done
			record "encode/vp9-workers/$id-${workers}w" "VP9, the 1080p synthetic animation, $kind, $(plural "$workers" worker)" "$best" "" fps "" 30fps
		done
	done
}

# Alpha video through video.Reader (oicut only) ----------------------------

ALPHA=(
	"prores4444|prores_4444_1080p.mov|ProRes 4444 + alpha, 1080p"
	"prores422hq|prores_422hq_1080p.mov|ProRes 422 HQ, 1080p"
	"vp9-alpha|vp9_alpha_1080p.webm|VP9 + alpha stream, GOP 30, 1080p"
	"vp9|vp9_1080p.webm|VP9, GOP 60, two-pass, 1080p"
	"transparent|transparent.mov|fframes transparent.mov, 640×360 ProRes 4444"
)

alpha_one() { # id file label
	local path=$IN/alpha/$2 threads r out fps=() seek=()
	[ "$2" = transparent.mov ] && path=demo/media/transparent.mov
	for threads in 1 8; do
		fps=() seek=()
		for r in 1 2 3 4 5; do
			if [ $threads = 1 ]; then out=$(pinned "$BIN/oicut_alpha" "$path" - 1); else out=$("$BIN/oicut_alpha" "$path" - 8); fi
			fps+=("$(echo "$out" | sed -n 's/.*frames, \([0-9.]*\) fps.*/\1/p')")
			seek+=("$(echo "$out" | sed -n 's/.*latency median \([0-9.]*\) ms.*/\1/p')")
		done
		record "alpha/$1/fps-${threads}t" "$3, $(plural "$threads" thread), frames through RGBA" \
			"$(printf '%s\n' "${fps[@]}" | median)" "" fps "" 30fps
		record "alpha/$1/seek-${threads}t" "$3, $(plural "$threads" thread), random frame_at seek" \
			"$(printf '%s\n' "${seek[@]}" | median)" "" ms ""
	done
}

# Vulkan Video (GPU) ------------------------------------------------------

# Per frame through video.Reader's planar output (the file read as it
# goes), against FFmpeg's Vulkan Video with every frame downloaded and, for
# AV1, dav1d on the CPU (both with packets in memory).
per_frame() { awk -v ms="$(echo "$1" | field codec_ms)" -v n="$(echo "$1" | field frames)" 'BEGIN {printf "%.3f", ms / n}'; }
gpu_decode() {
	local spec id file label decoder depth r runs ours
	for spec in "h264|h264-high.mp4|h264|1080p H.264, B-frames, 162 frames" "h265|hevc-main.mp4|hevc|1080p H.265, 162 frames" \
		"av1|av1-720p10.mp4|av1|720p 10-bit AV1 (SVT-AV1), 162 frames"; do
		IFS='|' read -r id file decoder label <<<"$spec"
		for depth in 1 3; do
			runs=()
			for r in 1 2 3; do runs+=("$("$BIN/gpu_decode$depth" "$IN/$file" | sed -n 's/.*frames, \([0-9.]*\) ms\/frame.*/\1/p')"); done
			ours=$(printf '%s\n' "${runs[@]}" | median)
			record "gpu/decode-$id/depth$depth" "$label, video.Reader planar, $(plural "$depth" picture) in flight" "$ours" "" ms/frame "" "${CLIP_FPS}fps"
		done
		record "gpu/decode-$id/ffmpeg-vulkan" "$label, three pictures in flight against FFmpeg's Vulkan Video, frames downloaded" \
			"$ours" "$(per_frame "$(HWACCEL=vulkan "$BIN/reference_decode" "$IN/$file" video "$decoder")")" ms/frame "$FFMPEG Vulkan Video" "${CLIP_FPS}fps"
		if [ "$id" = av1 ]; then
			record gpu/decode-av1/dav1d-1t "$label, three pictures in flight against dav1d on one core" \
				"$ours" "$(per_frame "$(pinned "$BIN/reference_decode" "$IN/$file" video libdav1d)")" ms/frame "dav1d 1.5.4" "${CLIP_FPS}fps"
			record gpu/decode-av1/dav1d-all "$label, three pictures in flight against dav1d on every core" \
				"$ours" "$(per_frame "$(THREADS=$(nproc) "$BIN/reference_decode" "$IN/$file" video libdav1d)")" ms/frame "dav1d 1.5.4" "${CLIP_FPS}fps"
		fi
	done
}

# 900 1080p pictures through video.Writer (the encode, its upload and the
# MP4 written to memory), against FFmpeg's Vulkan Video encoder set up the
# same way (tests/reference_vulkan_encode.c, no container); both at QP 23 on
# the same hardware encoder, so the sizes should agree too.
gpu_encode() {
	local codec name depth out ours ours_bytes theirs
	for codec in h264 h265; do
		name=$([ $codec = h264 ] && echo H.264 || echo H.265)
		for depth in 1 3; do
			out=$("$BIN/gpu_encode$depth" $codec)
			ours=$(echo "$out" | sed -n 's/.*, \([0-9.]*\) ms\/frame.*/\1/p')
			ours_bytes=$(echo "$out" | sed -n 's/.*; \([0-9]*\) bytes.*/\1/p')
			record "gpu/encode-$codec/depth$depth" "$name, 900 1080p I420 frames through video.Writer, $(plural "$depth" picture) in flight" \
				"$ours" "" ms/frame "" 30fps
		done
		theirs=$("$BIN/reference_vulkan_encode" $codec)
		record "gpu/encode-$codec/ffmpeg-vulkan" "$name, 900 1080p frames, three pictures in flight against FFmpeg's Vulkan Video encoder" \
			"$ours" "$(echo "$theirs" | field ms_per_frame)" ms/frame "$FFMPEG Vulkan Video" 30fps
		record "gpu/encode-$codec/ffmpeg-vulkan-bytes" "$name, 900 1080p frames at QP 23, size (oicut in MP4)" \
			"$ours_bytes" "$(echo "$theirs" | field bytes)" bytes "$FFMPEG Vulkan Video"
	done
}

# Cases --------------------------------------------------------------------

cases() {
	local c
	for c in "${DECODE[@]}"; do echo "decode/${c%%|*}"; done
	printf '%s\n' decode/webp-corpus decode/jpeg decode/stb decode/vorbis decode/streams-h264 decode/streams-h265 \
		encode/h264 encode/h264-16 encode/h265 encode/vp9 encode/vp9-animation encode/vp9-workers encode/aac encode/aac-fixture
	for c in "${ALPHA[@]}"; do echo "alpha/${c%%|*}"; done
	printf '%s\n' gpu/decode gpu/encode
}

run_case() {
	local c
	case $1 in
	decode/webp-corpus) decode_webp_corpus ;;
	decode/jpeg) decode_jpeg ;;
	decode/stb) decode_stb ;;
	decode/vorbis) decode_vorbis ;;
	decode/streams-h264) decode_streams h264 h264-high.264 "1080p H.264 High, 162 frames" h264 ;;
	decode/streams-h265) decode_streams h265 hevc-main.265 "1080p HEVC Main, 162 frames" hevc ;;
	decode/*)
		for c in "${DECODE[@]}"; do
			IFS="|" read -r id file kind label against decoder threads <<<"$c"
			if [ "decode/$id" = "$1" ]; then decode_one "$id" "$file" "$kind" "$label" "$against" "$decoder" "$threads"; fi
		done ;;
	encode/h264) encode_h264 ;;
	encode/h264-16) encode_h264_16 ;;
	encode/h265) encode_h265 ;;
	encode/vp9) encode_vp9 ;;
	encode/vp9-animation) encode_vp9_animation ;;
	encode/vp9-workers) encode_vp9_workers ;;
	encode/aac) encode_aac ;;
	encode/aac-fixture) encode_aac_fixture ;;
	alpha/*)
		for c in "${ALPHA[@]}"; do
			IFS='|' read -r id file label <<<"$c"
			if [ "alpha/$id" = "$1" ]; then alpha_one "$id" "$file" "$label"; fi
		done ;;
	gpu/decode) gpu_decode ;;
	gpu/encode) gpu_encode ;;
	esac
}

run() {
	local pattern=${1:-} c
	REVISION=$(revision)
	MACHINE=$(lscpu | sed -n 's/^Model name: *//p' | sed 's/ [0-9]*-Core Processor//')
	: > "$WORK/recorded"
	GPU_NAME=${GPU:-$(lspci -mm 2>/dev/null | awk -F'"' '/"(VGA|Display|3D)/ && !n++ {print $6}')}
	for c in $(cases); do
		if [ -z "$pattern" ]; then [[ $c == gpu/* ]] && continue; else [[ $c =~ $pattern ]] || continue; fi
		run_case "$c"
	done
	# A full run drops the rows it did not measure (renamed or removed cases),
	# keeping gpu/, which runs only when asked for.
	if [ -z "$pattern" ]; then
		awk -F'\t' 'FILENAME == ARGV[1] {keep[$1] = 1; next} FNR == 1 || $1 ~ /^gpu\// || $1 in keep' "$WORK/recorded" "$TSV" > "$TSV.new"
		mv "$TSV.new" "$TSV"
	fi
	doc
}

# The document -------------------------------------------------------------

doc() {
	[ -s "$TSV" ] || { echo "no $TSV yet: bash tests/compare.sh run" >&2; return 1; }
	awk -F'\t' '
	function num(v,   a) {
		if (v == "") return ""
		a = v < 0 ? -v : v
		return a >= 100 ? sprintf("%.0f", v) : a >= 10 ? sprintf("%.1f", v) : sprintf("%.2f", v)
	}
	function measured(i) { return date[i] " · " rev[i] " · load " load[i] }
	# How many times faster than real time a value is, from what it covers.
	function realtime(v, u, b,   x) {
		if (v == "" || b == "") return ""
		if (b ~ /fps$/) {
			b = substr(b, 1, length(b) - 3)
			x = u == "fps" ? v / b : u == "ms/frame" ? 1000 / (v * b) : ""
		} else if (b ~ /s$/ && u == "ms") x = substr(b, 1, length(b) - 1) * 1000 / v
		if (x == "") return ""
		return (x >= 100 ? sprintf("%.0f", x) : x >= 10 ? sprintf("%.1f", x) : sprintf("%.2f", x)) "×"
	}
	function realtimes(i,   a, b) {
		a = realtime(oicut[i], unit[i], basis[i]); b = realtime(reference[i], unit[i], basis[i])
		return b == "" ? a : a " / " b
	}
	function table(prefix, title, intro,   i, k, n) {
		for (i = 1; i <= rows; i++) if (index(id[i], prefix) == 1) n++
		if (!n) return
		print "## " title "\n\n" intro "\n"
		if (prefix == "alpha/") {
			print "| Figure | oicut | Unit | × real time | Machine | Measured |\n| --- | --- | --- | --- | --- | --- |"
			for (k = 1; k <= ncase; k++) for (i = 1; i <= rows; i++) if (rank[i] == k && index(id[i], prefix) == 1)
				printf "| %s | %s | %s | %s | %s | %s |\n", label[i], num(oicut[i]), unit[i], realtimes(i), machine[i], measured(i)
		} else {
			print "| Input | oicut | Reference | Unit | Ratio | × real time (oicut / reference) | Reference implementation | Machine | Measured |"
			print "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
			for (k = 1; k <= ncase; k++) for (i = 1; i <= rows; i++) if (rank[i] == k && index(id[i], prefix) == 1)
				printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", label[i],
					unit[i] == "% BD-rate" ? sprintf("%+.1f%%", oicut[i]) : num(oicut[i]), num(reference[i]),
					unit[i], ratio[i], realtimes(i), against[i], machine[i], measured(i)
		}
		print ""
	}
	NR > 1 {
		rows++; id[rows] = $1; label[rows] = $2; oicut[rows] = $3; reference[rows] = $4; unit[rows] = $5
		ratio[rows] = $6; against[rows] = $7; date[rows] = $8; rev[rows] = $9; machine[rows] = $10; load[rows] = $11; basis[rows] = $12
	}
	END {
		# Rows in the order of their cases (the longest case id each row id
		# starts with), whatever order they were measured in.
		ncase = split(order, cases, " ")
		for (i = 1; i <= rows; i++) {
			rank[i] = ncase
			best = 0
			for (k = 1; k <= ncase; k++) {
				c = cases[k]
				if ((id[i] == c || index(id[i], c "/") == 1 || index(id[i], c "-") == 1) && length(c) > best) {
					rank[i] = k
					best = length(c)
				}
			}
		}
		print "# Benchmarks\n"
		print "Generated by `bash tests/compare.sh` from [BENCHMARKS.tsv](BENCHMARKS.tsv), one row per figure;"
		print "rerun a case to replace its rows (`bash tests/compare.sh run decode/vp9`), never edit this file."
		print "The references are built from their pinned sources (THIRD_PARTY_REFERENCES.md). A ratio above 1"
		print "means oicut is slower, or for frame rates that the reference is faster. Measured gives the date,"
		print "the oicut revision (`+` and a hash when the working copy had changes) and the load average."
		print "× real time is how many times faster than playback each side runs: the length of the media over"
		print "the time taken, video at its clip'\''s frame rate (25 fps for the camera clips, 30 for the synthetic"
		print "ones); for independent streams it is how many real-time streams run at once.\n"
		table("decode/", "Decoding", "One thread pinned to one core, packets or the file resident in memory, opening the decoder not timed; the median of seven after a warmup unless the input says otherwise. The video is OpenH264'\''s 1080p fixture looped three times; the audio is the 320 s of decoded RFC 8251 Opus test vectors; both are encoded with x264, x265, libvpx, `prores_ks`, libwebp, `mjpeg` and FFmpeg'\''s audio encoders.")
		table("encode/", "Encoding", "Resident input, a fresh encoder per round, the median of seven. Speed is at one operating point; BD-rate is oicut'\''s size change at equal PSNR (FFmpeg'\''s sample-weighted Y, U, V) over four, piecewise-linear in log rate: negative means oicut is smaller. Every stream is decoded by FFmpeg and by oicut, identically. The video is OpenH264'\''s 54-frame 1080p fixture.")
		table("alpha/", "Alpha video (oicut only)", "`tests/movie_alpha.odin` through `video.Reader`, file input, frames converted to RGBA; the clips are `tests/alpha_fixtures.sh --large`'\''s. One thread pinned to one core; eight threads unpinned. Medians of five runs; seeks are the median of 40 random `frame_at` calls.")
		table("gpu/", "Vulkan Video", "Decode: `tests/movie_decode_timing.odin` through `video.Reader`'\''s planar output, the file read as it goes, the best of five per run and the median of three runs; against FFmpeg'\''s Vulkan Video with each frame downloaded, and dav1d on the CPU, both with packets in memory. Encode: `tests/movie_encode_timing.odin`, the median of five; its output bytes are identical at every depth. Run on request only: `bash tests/compare.sh run gpu/`.")
	}' order="$(cases | tr '\n' ' ')" "$TSV" > "$DOC"
	echo "wrote $DOC"
}

case ${1:-} in
build) build ;;
inputs) inputs ;;
run) run "${2:-}" ;;
doc) doc ;;
list) cases ;;
*) echo "usage: bash tests/compare.sh build|inputs|run [REGEX]|doc|list" >&2; exit 2 ;;
esac
