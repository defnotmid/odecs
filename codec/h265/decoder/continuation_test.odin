package h265_decoder

import common "../../common"
import enc "../encoder"
import "core:testing"

@(private)
Continuation_Leaf :: struct {
	payload: []u8,
	rec:     []enc.Sample,
}

// Produce one independently coded CTB with our native encoder. Uniform 128
// is the exact reference for every P candidate, including edge emulation;
// the I leaf has distinct luma/Cb/Cr detail and a separately retained oracle.
@(private)
continuation_leaf :: proc(kind: Slice_Type) -> (leaf: Continuation_Leaf, ok: bool) {
	cfg := enc.Config {
		width       = 64,
		height      = 64,
		qp          = 26,
		level_idc   = 120,
		forced_mode = -1,
		deblock     = false,
		sao         = false,
	}
	e: enc.Encoder
	enc.init_encoder(&e, cfg)
	defer enc.destroy_encoder(&e)
	y: [64 * 64]enc.Sample
	u, v: [32 * 32]enc.Sample
	for &value in y do value = 128
	for &value in u do value = 128
	for &value in v do value = 128
	stream: [dynamic]u8
	defer delete(stream)
	if kind == .P {
		enc.encode_frame(&e, raw_data(y[:]), raw_data(u[:]), raw_data(v[:]), 64, 32, &stream)
	} else {
		for j in 0 ..< 64 do for i in 0 ..< 64 do y[j * 64 + i] = enc.Sample((i * 3 + j * 5 + (i / 8 + j / 8) % 2 * 19 + 23) & 255)
		for j in 0 ..< 32 {
			for i in 0 ..< 32 {
				u[j * 32 + i] = enc.Sample((i * 7 + j * 11 + 31) & 255)
				v[j * 32 + i] = enc.Sample((i * 13 + j * 3 + 137) & 255)
			}
		}
	}
	enc.encode_frame(&e, raw_data(y[:]), raw_data(u[:]), raw_data(v[:]), 64, 32, &stream)
	nals := split_annex_b(stream[:])
	defer {
		for &nal in nals do destroy_nal(&nal)
		delete(nals)
	}
	sps_nal, pps_nal := find_nal(nals[:], .SPS_NUT), find_nal(nals[:], .PPS_NUT)
	if sps_nal == nil || pps_nal == nil do return
	s, sok := parse_sps(sps_nal.rbsp)
	defer destroy_sps(&s)
	p, pok := parse_pps(pps_nal.rbsp)
	defer destroy_pps(&p)
	if !sok || !pok do return
	chosen: ^Nal_Unit
	for &nal in nals do if nal_type_is_vcl(nal.type) do chosen = &nal
	if chosen == nil do return
	sh, parsed := parse_slice_header(chosen.rbsp, chosen.type, &s, &p)
	defer destroy_slice_header(&sh)
	if !parsed || sh.slice_type != kind do return
	leaf.payload = clone_slice(chosen.rbsp[sh.data_offset:])
	leaf.rec = make([]enc.Sample, 64 * 64 + 2 * 32 * 32)
	for j in 0 ..< 64 do copy(leaf.rec[j * 64:(j + 1) * 64], e.rec.y.data[e.rec.y.offset + j * e.rec.y.stride:][:64])
	for j in 0 ..< 32 {
		copy(
			leaf.rec[4096 + j * 32:4096 + (j + 1) * 32],
			e.rec.u.data[e.rec.u.offset + j * e.rec.u.stride:][:32],
		)
		copy(
			leaf.rec[5120 + j * 32:5120 + (j + 1) * 32],
			e.rec.v.data[e.rec.v.offset + j * e.rec.v.stride:][:32],
		)
	}
	return leaf, true
}

// The SPS picture is two CTBs wide. Each TRAIL_R NAL carries one complete,
// independently initialized CTB; both slices retain the same preceding POC.
// Only slice_type differs, so the filter and picture-RPS domains stay fixed.
@(private)
append_continuation_leaf :: proc(
	stream: ^[dynamic]u8,
	kind: Slice_Type,
	first: bool,
	payload: []u8,
) {
	rbsp: [dynamic]u8
	defer delete(rbsp)
	w := common.init_bit_writer(&rbsp)
	common.write_bits(&w, first ? 1 : 0, 1)
	common.write_ue(&w, 0) // PPS id
	if !first do common.write_bits(&w, 1, 1) // raster CTB address
	common.write_ue(&w, u32(kind))
	common.write_bits(&w, 1, 8) // POC LSB
	common.write_bits(&w, 0, 1) // slice-owned short-term RPS
	common.write_ue(&w, 1) // one negative reference
	common.write_ue(&w, 0) // no positive references
	common.write_ue(&w, 0) // preceding POC
	common.write_bits(&w, 1, 1) // used reference
	if kind == .P {
		common.write_bits(&w, 0, 1) // one active reference, PPS default
		common.write_ue(&w, 0) // five merge candidates
	}
	common.write_se(&w, 0) // QP 26
	common.write_rbsp_trailing_bits(&w) // header byte alignment
	append(&rbsp, ..payload)
	header := [2]u8{u8(Nal_Type.TRAIL_R) << 1, 1}
	common.append_nal_annex_b(stream, header[:], rbsp[:])
}

@(test)
test_independent_continuation_uses_active_header :: proc(t: ^testing.T) {
	i_leaf, i_ok := continuation_leaf(.I)
	p_leaf, p_ok := continuation_leaf(.P)
	defer delete(i_leaf.payload)
	defer delete(i_leaf.rec)
	defer delete(p_leaf.payload)
	defer delete(p_leaf.rec)
	testing.expect(t, i_ok && p_ok)
	if !i_ok || !p_ok do return
	kinds := [2]Slice_Type{.I, .P}
	for first_kind in kinds {
		for second_kind in kinds {
			cfg := enc.Config {
				width       = 128,
				height      = 64,
				qp          = 26,
				level_idc   = 120,
				forced_mode = -1,
				deblock     = false,
				sao         = false,
			}
			e: enc.Encoder
			enc.init_encoder(&e, cfg)
			stream := encode_test_frames(&e, 1, 128, 64)
			enc.destroy_encoder(&e)
			defer delete(stream)
			leaves := [2]Continuation_Leaf{i_leaf, p_leaf}
			first := first_kind == .I ? leaves[0] : leaves[1]
			second := second_kind == .I ? leaves[0] : leaves[1]
			append_continuation_leaf(&stream, first_kind, true, first.payload)
			append_continuation_leaf(&stream, second_kind, false, second.payload)
			nals := split_annex_b(stream[:])
			defer {
				for &nal in nals do destroy_nal(&nal)
				delete(nals)
			}
			d: Decoder
			init_decoder(&d)
			defer destroy_decoder(&d)
			out: [dynamic]^Picture
			defer {
				for pic in out do testing.expect(t, release_picture(&d, pic))
				delete(out)
			}
			good := true
			picture_header: ^Slice_Header
			for &nal in nals {
				if !decode_nal(&d, nal, &out) {
					good = false
					break
				}
				if nal.type == .TRAIL_R {
					ctu := d.ctu.(^Ctu_Decoder(u8))
					if picture_header == nil do picture_header = ctu.sh
					testing.expect_value(t, ctu.sh, picture_header)
				}
			}
			testing.expectf(t, good, "two slices %v/%v refused", first_kind, second_kind)
			if !good do continue
			testing.expect_value(t, d.prev_slice.slice_type, second_kind)
			ctu := d.ctu.(^Ctu_Decoder(u8))
			testing.expect_value(t, ctu.sh.slice_type, first_kind)
			testing.expect_value(t, ctu.grids.ctb_slice_addr[1], i32(1))
			for y := 0; y < 64; y += 4 do for x := 64; x < 128; x += 4 do testing.expect_value(t, ctu.grids.blk[blk_index(ctu, x, y)].intra, second_kind == .I)

			// A rejected substream also restores the original owned pointer;
			// destroying a temporary segment header cannot poison the CTU.
			temporary := Slice_Header {
				slice_type            = second_kind,
				slice_segment_address = 1,
				data_offset           = 1,
			}
			testing.expect(t, !decode_slice_data(ctu, {rbsp = nil}, &temporary))
			testing.expect_value(t, ctu.sh, picture_header)
			flush_decoder(&d, &out)
			testing.expect_value(t, len(out), 2)
			if len(out) != 2 do continue
			pic := out[1]
			for lane in 0 ..< 2 {
				leaf := lane == 0 ? first : second
				for c in 0 ..< 3 {
					plane, stride := plane_at(u8, pic, c)
					width := c == 0 ? 64 : 32
					height := c == 0 ? 64 : 32
					base := c == 0 ? 0 : c == 1 ? 4096 : 5120
					for j in 0 ..< height {
						for i in 0 ..< width {
							testing.expect_value(
								t,
								enc.Sample(plane[j * stride + lane * width + i]),
								leaf.rec[base + j * width + i],
							)
						}
					}
				}
			}
		}
	}
}
