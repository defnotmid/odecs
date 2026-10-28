package common

import "core:math"

Chapter :: struct {
	start: f64, // seconds
	title: string, // UTF-8
}

// Checks chapter ordering and titles before the media duration is known:
// starts must be finite and strictly increasing from 0, and every title
// non-empty.
validate_chapters :: proc(chapters: []Chapter) -> bool {
	for c, i in chapters {
		if len(c.title) == 0 || math.is_nan(c.start) || math.is_inf(c.start, 0) do return false
		if i == 0 {
			if c.start != 0 do return false
		} else if !(c.start > chapters[i - 1].start) {
			return false
		}
	}
	return true
}
