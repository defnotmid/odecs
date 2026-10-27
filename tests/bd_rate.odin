// Bjøntegaard deltas of encoder A against encoder B from their rate/quality
// points: BD-rate is A's average size change at equal quality (negative:
// A is smaller), BD-PSNR A's average quality change at equal size. Both
// curves are piecewise-linear in log rate and integrated exactly over the
// range the two share. tests/compare.sh runs it for its encode cases.
//
//   odin run tests/bd_rate.odin -file -- BYTES:PSNR,BYTES:PSNR,... BYTES:PSNR,...
package bd_rate

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Point :: struct {
	x, y: f64,
}

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(2)
}

// Points as (log rate, quality).
parse :: proc(text: string) -> []Point {
	points: [dynamic]Point
	for item in strings.split(text, ",") {
		parts := strings.split(item, ":")
		if len(parts) != 2 do fail("expected BYTES:PSNR, got", item)
		bytes, ok_bytes := strconv.parse_f64(parts[0])
		psnr, ok_psnr := strconv.parse_f64(parts[1])
		if !ok_bytes || !ok_psnr || bytes <= 0 do fail("bad point", item)
		append(&points, Point{math.ln(bytes), psnr})
	}
	if len(points) < 2 do fail("at least two points per encoder")
	return points[:]
}

// The integral over [lo, hi] of the line through points sorted by x.
integral :: proc(points: []Point, lo, hi: f64) -> f64 {
	sum := 0.0
	for i in 0 ..< len(points) - 1 {
		a, b := points[i], points[i + 1]
		x0, x1 := max(a.x, lo), min(b.x, hi)
		if x1 <= x0 || b.x == a.x do continue
		y0 := a.y + (b.y - a.y) * (x0 - a.x) / (b.x - a.x)
		y1 := a.y + (b.y - a.y) * (x1 - a.x) / (b.x - a.x)
		sum += (y0 + y1) * (x1 - x0) / 2
	}
	return sum
}

// The mean of B minus A over the x range both cover.
mean_delta :: proc(a, b: []Point) -> f64 {
	by_x :: proc(p, q: Point) -> bool {return p.x < q.x}
	slice.sort_by(a, by_x)
	slice.sort_by(b, by_x)
	lo, hi := max(a[0].x, b[0].x), min(a[len(a) - 1].x, b[len(b) - 1].x)
	if hi <= lo do fail("the two curves share no range")
	return (integral(b, lo, hi) - integral(a, lo, hi)) / (hi - lo)
}

main :: proc() {
	if len(os.args) != 3 do fail("usage: bd_rate BYTES:PSNR,... BYTES:PSNR,...")
	a, b := parse(os.args[1]), parse(os.args[2])
	bd_psnr := mean_delta(b, a)
	swap :: proc(points: []Point) {for &p in points do p.x, p.y = p.y, p.x}
	swap(a)
	swap(b)
	bd_rate := (math.exp(mean_delta(b, a)) - 1) * 100
	fmt.printfln("bd_rate=%.2f bd_psnr=%.3f", bd_rate, bd_psnr)
}
