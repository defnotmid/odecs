#!/usr/bin/env bash
# What CI runs (.github/workflows/ci.yml), runnable locally too:
#
#   bash .github/ci.sh check             # the facades' import layers; odin check -vet -strict-style, every package
#                                        # (and with -define:ODECS_PATENTED=true where native H.264/H.265 is gated)
#   bash .github/ci.sh check --programs  # and the tests/*.odin programs (Linux-only tools), and that a
#                                        # default build links no native H.264/H.265 coding
#   bash .github/ci.sh test              # odin test, every package that has tests (-o:none:
#                                        # -o:speed spends minutes compiling, tests run in ~40 s)
#
# GPU and fixture tests stay off: they need -define:ODECS_GPU_TEST and friends.
set -uo pipefail
cd "$(dirname "$0")/.."

out=${RUNNER_TEMP:-${TMPDIR:-/tmp}}/odecs-ci
mkdir -p "$out"
exe=
[ "${OS:-}" = Windows_NT ] && exe=.exe

packages() { git ls-files '*.odin' | grep -v '^tests/' | xargs -n1 dirname | sort -u; }
test_packages() { git ls-files '*_test.odin' | xargs -n1 dirname | sort -u; }

# A relative path with its ".." segments resolved (portable: no GNU realpath).
normal() {
	local out=() part
	local IFS=/
	for part in $1; do
		case $part in
		'' | .) ;;
		..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
		*) out+=("$part") ;;
		esac
	done
	echo "${out[*]}"
}

# The odecs packages a package imports, itself included, transitively.
imports() {
	local -A seen=()
	local queue=("$1") p f rel
	while [ ${#queue[@]} -gt 0 ]; do
		p=${queue[0]}; queue=("${queue[@]:1}")
		[ -n "${seen[$p]:-}" ] && continue
		seen[$p]=1
		echo "$p"
		for f in "$p"/*.odin; do
			case "$f" in *_test.odin) continue ;; esac
			for rel in $(grep -oE '^(@\(require\) )?import( [a-z_0-9]+)? "\.\.?(/[^"]*)?"' "$f" | grep -oE '"[^"]+"' | tr -d '"'); do
				queue+=("$(normal "$p/$rel")")
			done
		done
	done
}

# The families stay apart: audio links no media, video or image code, and image
# no audio, video, media or container code.
layers() {
	local bad
	bad=$(imports audio | grep -E '^(media|video|image)(/|$)')
	[ -z "$bad" ] || { echo "audio imports: $bad"; return 1; }
	bad=$(imports image | grep -E '^(media|video|audio|container)(/|$)')
	[ -z "$bad" ] || { echo "image imports: $bad"; return 1; }
}

# A default build links no native H.264 or H.265 slice decoding or encoding:
# only the parsing the hardware providers use (mp4_smoke reads and writes
# through the video facade).
patent_free() {
	odin build tools/mp4_smoke -o:none -out:"$out/mp4_smoke" || return 1
	! nm "$out/mp4_smoke" | grep -E 'h26[45]_decoder::decode_|h264_encoder::|h265_encoder::encode'
}

failed=()
run() {
	local name=$1; shift
	echo "::group::$name"
	if "$@"; then echo "::endgroup::"; else echo "::endgroup::"; echo "::error::$name failed"; failed+=("$name"); fi
}

odin version
case ${1:-} in
check)
	run "layers" layers
	for p in $(packages); do run "check $p" odin check "$p" -vet -strict-style -no-entry-point; done
	# Native H.264 and H.265 are compiled out by default (on under odin test):
	# check those branches as well.
	for p in $(git grep -l ODECS_PATENTED -- '*.odin' ':!tests' | xargs -n1 dirname | sort -u); do
		run "check $p ODECS_PATENTED" odin check "$p" -vet -strict-style -no-entry-point -define:ODECS_PATENTED=true
	done
	if [ "${2:-}" = --programs ]; then
		for f in tests/*.odin; do run "check $f" odin check "$f" -file -vet -strict-style; done
		run "patent-free default build" patent_free
	fi
	;;
test)
	for p in $(test_packages); do run "test $p" odin test "$p" -o:none -out:"$out/odecs-test$exe"; done
	;;
*)
	echo "usage: bash .github/ci.sh check [--programs] | test" >&2
	exit 2
	;;
esac

if [ ${#failed[@]} -ne 0 ]; then
	printf 'failed: %s\n' "${failed[@]}" >&2
	exit 1
fi
