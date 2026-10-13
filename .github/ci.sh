#!/usr/bin/env bash
# What CI runs (.github/workflows/ci.yml), runnable locally too:
#
#   bash .github/ci.sh check             # odin check -vet -strict-style, every package
#   bash .github/ci.sh check --programs  # and the tests/*.odin programs (Linux-only tools)
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

failed=()
run() {
	local name=$1; shift
	echo "::group::$name"
	if "$@"; then echo "::endgroup::"; else echo "::endgroup::"; echo "::error::$name failed"; failed+=("$name"); fi
}

odin version
case ${1:-} in
check)
	for p in $(packages); do run "check $p" odin check "$p" -vet -strict-style -no-entry-point; done
	if [ "${2:-}" = --programs ]; then
		for f in tests/*.odin; do run "check $f" odin check "$f" -file -vet -strict-style; done
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
