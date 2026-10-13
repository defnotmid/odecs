#!/usr/bin/env bash
# Fetches the JCT-VC HEVC version 1 conformance streams into $HEVC (default
# .work/hevc-conformance): each stream's .bit/.bin, and in md5/ the MD5 files
# of its decoded output. Existing downloads are kept.
set -euo pipefail
cd "$(dirname "$0")/.."
HEVC=${HEVC:-.work/hevc-conformance}
BASE=https://www.itu.int/wftp3/av-arch/jctvc-site/bitstream_exchange/draft_conformance/HEVC_v1
mkdir -p "$HEVC/zip" "$HEVC/md5"
for z in $(curl -fsSL "$BASE/" | grep -oE '[A-Za-z0-9_]+\.zip' | sort -u); do
	[ -f "$HEVC/zip/$z" ] || curl -fsSL -o "$HEVC/zip/$z" "$BASE/$z"
	unzip -qo -j "$HEVC/zip/$z" '*.bit' '*.bin' -d "$HEVC" 2>/dev/null || true
	unzip -qo -j "$HEVC/zip/$z" '*md5*' -d "$HEVC/md5" 2>/dev/null || true
done
echo "$(ls "$HEVC"/*.bit "$HEVC"/*.bin 2>/dev/null | wc -l | tr -d ' ') streams in $HEVC"
