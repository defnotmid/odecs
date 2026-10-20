#!/usr/bin/env bash
# Image gate: every fixture (tests/image_fixtures.sh) through odecs/image
# against stb_image (tests/image_compare.odin: lossless formats identical),
# every GIF animation frame against a browser's (Chromium's ImageDecoder,
# when chromium is installed), and a fuzz pass over the fixtures.
# Development only; stb and Chromium are oracles.
#   bash tests/image_check.sh [work-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
work=${1:-.work/image-check}
fx=.work/image-fixtures
mkdir -p "$work/frames"
fail=0

for p in bmp gif png/encoder wav webp; do odin test "$p" > "$work/test.log" 2>&1 || { cat "$work/test.log"; fail=1; }; done
bash tests/image_fixtures.sh "$fx" > /dev/null
files=$(ls "$fx"/*.{png,gif,bmp,tga,qoi,webp} 2>/dev/null)

echo "== against stb_image"
# shellcheck disable=SC2086
odin run tests/image_compare.odin -file -o:speed -- $files || fail=1

# Chromium's composited frames, as NAME.K.rgba: the page decodes the file
# with ImageDecoder and prints each frame's pixels in base64.
chromium_frames() {
	local in=$1 name page
	name=$(basename "${in%.*}")
	page=$work/frames/$name.html
	cat > "$page" <<HTML
<html><body><pre id=o></pre><script>
(async () => {
	const bytes = Uint8Array.from(atob("$(base64 -w0 "$in")"), c => c.charCodeAt(0));
	const d = new ImageDecoder({data: bytes, type: "image/gif"});
	await d.tracks.ready;
	let s = "";
	for (let k = 0; k < d.tracks.selectedTrack.frameCount; k++) {
		const {image} = await d.decode({frameIndex: k});
		const c = new OffscreenCanvas(image.displayWidth, image.displayHeight);
		const g = c.getContext("2d");
		g.drawImage(image, 0, 0);
		let bin = "";
		for (const v of g.getImageData(0, 0, c.width, c.height).data) bin += String.fromCharCode(v);
		s += "FRAME:" + btoa(bin) + "\n";
		image.close();
	}
	document.getElementById("o").textContent = s;
})();
</script></body></html>
HTML
	rm -f "$work/frames/$name".*.rgba
	local k=0
	while read -r data; do
		base64 -d <<< "$data" > "$work/frames/$name.$k.rgba"
		k=$((k + 1))
	done < <(chromium --headless=new --disable-gpu --virtual-time-budget=10000 --dump-dom "file://$PWD/$page" 2>/dev/null | grep -o 'FRAME:[A-Za-z0-9+/=]\+' | cut -d: -f2)
}

echo "== GIF animations against Chromium"
if command -v chromium > /dev/null; then
	for f in "$fx"/gif_anim_*.gif; do chromium_frames "$f"; done
	odin run tests/gif_animation_compare.odin -file -o:speed -- "$work/frames" "$fx"/gif_anim_*.gif || fail=1
else
	echo "  chromium not installed: skipped"
fi

echo "== fuzz"
odin build tests/image_fuzz.odin -file -o:speed -sanitize:address -out:"$work/image_fuzz"
# shellcheck disable=SC2086
"$work/image_fuzz" 300 $files || fail=1

[ $fail = 0 ] && echo "image gate: ok" || echo "image gate: FAILED"
exit $fail
