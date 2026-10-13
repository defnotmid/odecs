package h265_decoder

import "core:testing"

@(test)
test_long_term_reference_resolution :: proc(t: ^testing.T) {
	r: Ref_Pic_Set
	defer destroy_ref_pic_set(&r)
	append(&r.lt_curr, 1, 18)
	append(&r.lt_curr_lsb_only, true, false)
	append(&r.lt_foll, 3)
	append(&r.lt_foll_lsb_only, true)
	testing.expect(t, resolve_long_term_ref_pocs(&r, []i32{17, 18, 35}, 4))
	testing.expect_value(t, r.lt_curr[0], i32(17))
	testing.expect_value(t, r.lt_curr[1], i32(18))
	testing.expect_value(t, r.lt_foll[0], i32(35))
	// A missing LSB name remains untouched; ambiguous names preserve native
	// first-match semantics but cannot be admitted by a hardware frontend.
	r.lt_curr[0] = 1
	testing.expect(t, !resolve_long_term_ref_pocs(&r, []i32{18, 35}, 4))
	testing.expect_value(t, r.lt_curr[0], i32(1))
	r.lt_curr[0] = 1
	testing.expect(t, !resolve_long_term_ref_pocs(&r, []i32{17, 33, 18, 35}, 4))
	testing.expect_value(t, r.lt_curr[0], i32(17))
	clear(&r.lt_foll)
	clear(&r.lt_foll_lsb_only)
	r.lt_curr[0], r.lt_curr[1] = 17, 17
	r.lt_curr_lsb_only[0], r.lt_curr_lsb_only[1] = false, false
	testing.expect(t, !resolve_long_term_ref_pocs(&r, []i32{17}, 4))
	clear(&r.lt_curr)
	clear(&r.lt_curr_lsb_only)
	append(&r.lt_curr, 1, 1)
	append(&r.lt_curr_lsb_only, true, true)
	testing.expect(t, !resolve_long_term_ref_pocs(&r, []i32{17}, 4))
	testing.expect_value(t, r.lt_curr[0], i32(17))
	testing.expect_value(t, r.lt_curr[1], i32(1))
}
