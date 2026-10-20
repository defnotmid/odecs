#!/usr/bin/env bash
# Decoder speed against the pinned references, one codec at a time, decode
# only: packets resident in memory, a fresh decoder per round, one thread,
# pinned to one core, median of seven after a warmup. Development only.
#
#   bash tools/fetch_third_party.sh ffmpeg libvpx opus libwebp openh264
#   bash tests/opus_fixtures.sh              # the audio source (RFC 8251 vectors)
#   bash tests/decode_benchmark.sh [build|inputs|run|all]   (default: all; ONLY=regex picks cases)
#
# The references are built here from third_party/ (FFmpeg n9.0.2 decoders
# only, with libvpx and libopus; libwebp), never the system FFmpeg, so that a
# later run measures against the same code. The inputs are encoded once with
# the system ffmpeg from pinned material: OpenH264's 1080p fixture (54
# frames, looped three times) and the 320 s of decoded Opus test vectors.
# Each row prints both times and odecs/reference; above 1 odecs is slower.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=${WORK:-.work/decode-benchmark}
CPU=${CPU:-23}
JOBS=${JOBS:-$(nproc)}
STAGE=${1:-all}
mkdir -p "$WORK"
WORK=$(realpath "$WORK")
REF=$WORK/ref IN=$WORK/inputs
VECTORS=${VECTORS:-.work/opusfx/vectors/opus_newvectors}

build() {
	mkdir -p "$REF/prefix"
	local root=$PWD
	if [ ! -f "$REF/prefix/lib/libvpx.a" ]; then
		mkdir -p "$REF/libvpx" && (cd "$REF/libvpx" &&
			"$root/third_party/libvpx/configure" --prefix="$REF/prefix" --disable-examples --disable-tools \
				--disable-docs --disable-unit-tests --disable-vp8 --disable-vp9-encoder --enable-vp9-highbitdepth --enable-pic >/dev/null &&
			make -s -j"$JOBS" >/dev/null && make -s install >/dev/null)
	fi
	if [ ! -f "$REF/prefix/lib/libopus.a" ]; then
		cmake -S third_party/opus -B "$REF/opus" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$REF/prefix" \
			-DCMAKE_INSTALL_LIBDIR=lib -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF >/dev/null
		cmake --build "$REF/opus" -j"$JOBS" >/dev/null 2>&1 && cmake --install "$REF/opus" >/dev/null
	fi
	if [ ! -f "$REF/prefix/lib/libwebp.a" ]; then
		cmake -S third_party/libwebp -B "$REF/libwebp" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$REF/prefix" \
			-DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
			-DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
			-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF >/dev/null
		cmake --build "$REF/libwebp" -j"$JOBS" >/dev/null && cmake --install "$REF/libwebp" >/dev/null
	fi
	if [ ! -f "$REF/prefix/lib/libavcodec.a" ]; then
		mkdir -p "$REF/ffmpeg" && (cd "$REF/ffmpeg" &&
			PKG_CONFIG_PATH="$REF/prefix/lib/pkgconfig" "$root/third_party/ffmpeg/configure" \
				--prefix="$REF/prefix" --pkg-config-flags=--static --disable-everything --disable-programs --disable-doc \
				--disable-network --disable-autodetect --enable-static --disable-shared --enable-libvpx --enable-libopus \
				--enable-decoder=h264,hevc,vp9,libvpx_vp9,prores,aac,alac,flac,mp3float,opus,libopus \
				--enable-demuxer=mov,matroska,ogg,flac,mp3 \
				--enable-parser=h264,hevc,vp9,aac,flac,mpegaudio,opus --enable-bsf=vp9_superframe_split \
				--enable-protocol=file >/dev/null &&
			make -s -j"$JOBS" >/dev/null && make -s install >/dev/null)
	fi
	local pc="env PKG_CONFIG_PATH=$REF/prefix/lib/pkgconfig pkg-config --static"
	# shellcheck disable=SC2046
	c++ -std=c++17 -O3 -Wall -Wextra -Werror tests/reference_decode.cpp \
		$($pc --cflags --libs libavformat libavcodec libavutil) -o "$WORK/reference"
	# shellcheck disable=SC2046
	cc -std=c11 -O3 -Wall -Wextra -Werror tests/reference_webp.c $($pc --cflags --libs libwebp) -o "$WORK/reference_webp"
	odin build tests/decode_benchmark.odin -file -o:speed -microarch:native -out:"$WORK/odecs"
}

inputs() {
	mkdir -p "$IN"
	local ff=(ffmpeg -v error -y) video=$IN/source.y4m audio=$IN/source.wav
	if [ ! -f "$video" ]; then
		"${ff[@]}" -i third_party/openh264/res/VID_1920x1080_cabac_temporal_direct.264 -pix_fmt yuv420p "$IN/fixture.y4m"
		"${ff[@]}" -stream_loop 2 -i "$IN/fixture.y4m" -c copy "$video"
		rm "$IN/fixture.y4m"
	fi
	[ -f "$audio" ] || cat "$VECTORS"/testvector??.dec | "${ff[@]}" -f s16le -ar 48000 -ac 2 -i - "$audio"
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
	enc aac-lc.m4a "${a[@]}" -c:a aac -b:a 128k
	enc alac.m4a "${a[@]}" -c:a alac
	enc flac.flac "${a[@]}" -c:a flac -compression_level 5
	enc mp3.mp3 "${a[@]}" -c:a libmp3lame -b:a 192k
	enc opus.opus "${a[@]}" -c:a libopus -b:a 128k
	enc webp-lossy.webp -i "$video" -frames:v 1 -c:v libwebp -quality 75
	enc webp-lossless.webp -i "$video" -frames:v 1 -c:v libwebp -lossless 1
	[ -f "$IN/bryce.webp" ] || cp demo/media/bryce.webp "$IN/bryce.webp"
}

# name file kind [reference decoder]
CASES=(
	"H.264-High-8bit h264-high.mp4 video"
	"H.264-High10 h264-high10.mp4 video"
	"H.264-High422-10bit h264-high422.mp4 video"
	"HEVC-Main hevc-main.mp4 video"
	"HEVC-Main10 hevc-main10.mp4 video"
	"VP9-profile0 vp9-p0.webm video"
	"VP9-profile0(libvpx) vp9-p0.webm video libvpx-vp9"
	"VP9-profile2-10bit vp9-p2.webm video"
	"VP9-profile2(libvpx) vp9-p2.webm video libvpx-vp9"
	"ProRes-422HQ prores-hq.mov video"
	"ProRes-4444 prores-4444.mov video"
	"AAC-LC aac-lc.m4a audio"
	"ALAC alac.m4a audio"
	"FLAC flac.flac audio"
	"MP3 mp3.mp3 audio"
	"Opus opus.opus audio"
	"Opus(libopus) opus.opus audio libopus"
	"WebP-lossy-1080p webp-lossy.webp image"
	"WebP-lossless-1080p webp-lossless.webp image"
	"WebP-bryce bryce.webp image"
)

ms() { sed -n 's/.*codec_ms=\([0-9.]*\).*/\1/p'; }
units() { sed -n 's/.* \(frames\|samples\|pixels\)=\([0-9]*\).*/\2/p'; }

run() {
	printf '%-24s %12s %12s %8s  %s\n' case odecs_ms reference_ms ratio reference
	for c in "${CASES[@]}"; do
		read -r name file kind decoder <<<"$c"
		[[ $name =~ ${ONLY:-.} ]] || continue
		local ours theirs
		if ! ours=$(taskset -c "$CPU" "$WORK/odecs" "$IN/$file" "$kind" 2>&1); then
			printf '%-24s odecs failed: %s\n' "$name" "${ours#decode benchmark: }"
			continue
		fi
		if [ "$kind" = image ]; then
			theirs=$(taskset -c "$CPU" "$WORK/reference_webp" "$IN/$file" 2>&1)
		else
			theirs=$(taskset -c "$CPU" "$WORK/reference" "$IN/$file" "$kind" ${decoder:+"$decoder"} 2>&1)
		fi || { printf '%-24s reference failed: %s\n' "$name" "$(echo "$theirs" | tail -1)"; continue; }
		echo "$ours" >>"$WORK/run.log"
		echo "$theirs" >>"$WORK/run.log"
		local a b
		a=$(echo "$ours" | ms) b=$(echo "$theirs" | ms)
		# FFmpeg trims the audio encoders' delay and padding; odecs leaves that to movie.
		awk -v a="$(echo "$ours" | units)" -v b="$(echo "$theirs" | units)" \
			'BEGIN {d = a - b; exit !(b > 0 && (d < 0 ? -d : d) <= b / 1000)}' ||
			echo "  $name: odecs $(echo "$ours" | units) units, reference $(echo "$theirs" | units)" >&2
		printf '%-24s %12s %12s %8s  %s\n' "$name" "$a" "$b" "$(awk -v a="$a" -v b="$b" 'BEGIN {printf "%.2f", a / b}')" \
			"$(echo "$theirs" | sed -n 's/.*decoder=\([^ ]*\).*/\1/p')"
	done
}


case $STAGE in
build) build ;;
inputs) inputs ;;
run) run ;;
all) build && inputs && run ;;
*) echo "usage: bash tests/decode_benchmark.sh [build|inputs|run|all]" >&2; exit 2 ;;
esac
