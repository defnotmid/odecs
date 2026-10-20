package aac

import common "../../common"

MAX_CHANNELS :: 8
Element_Kind :: enum {
	SCE,
	CPE,
	LFE,
	CCE,
}
Channel_Element :: struct {
	kind:                    Element_Kind,
	tag:                     u8,
	first_channel, channels: int,
}
Channel_Layout :: struct {
	elements:                                       [MAX_CHANNELS]Channel_Element,
	element_count, channels, channel_configuration: int,
}
Program_Element :: struct {
	is_pair: bool,
	tag:     u8,
}
Program_Coupling :: struct {
	independent: bool,
	tag:         u8,
}
Program_Config :: struct {
	tag, object_type:                                                     u8, // object_type uses AudioObjectType values; 2 is AAC-LC
	sample_rate:                                                          int,
	front, side, back:                                                    [MAX_CHANNELS]Program_Element,
	front_count, side_count, back_count:                                  int,
	lfe:                                                                  [MAX_CHANNELS]u8,
	lfe_count:                                                            int,
	associated:                                                           [16]u8,
	associated_count:                                                     int,
	coupling:                                                             [16]Program_Coupling,
	coupling_count:                                                       int,
	mono_mixdown_present, stereo_mixdown_present, matrix_mixdown_present: bool,
	mono_mixdown_element, stereo_mixdown_element, matrix_mixdown_index:   u8,
	pseudo_surround:                                                      bool,
	comment:                                                              [255]u8,
	comment_bytes:                                                        int,
}

channels_for_configuration :: proc(configuration: int) -> int {
	if configuration >= 1 && configuration <= 6 do return configuration
	if configuration == 7 do return 8
	return 0
}

channel_configuration :: proc(c: Config) -> int {
	if c.use_pce || c.channels == 7 do return 0
	if c.channels == 8 do return 7
	return c.channels
}

resolve_channel_layout :: proc(c: Config) -> (layout: Channel_Layout, err: Error) {
	program := c.program_config
	if c.use_pce && program_config_present(&program) do return program_channel_layout(&program)
	if c.channels < 1 || c.channels > MAX_CHANNELS do return {}, .Unsupported_Channels
	layout.channel_configuration = channel_configuration(c)
	add :: proc(l: ^Channel_Layout, kind: Element_Kind, tag: u8) {
		count := kind == .CPE ? 2 : 1
		l.elements[l.element_count] = {kind, tag, l.channels, count}
		l.element_count += 1
		l.channels += count
	}
	if c.channels == 1 {add(&layout, .SCE, 0); return layout, .None}
	if c.channels == 2 {add(&layout, .CPE, 0); return layout, .None}
	// ISO/IEC 14496-3 predefined AAC order: front, side, back, then LFE.
	add(&layout, .SCE, 0)
	add(&layout, .CPE, 0)
	if c.channels == 4 {add(&layout, .SCE, 1); return layout, .None}
	if c.channels >= 7 do add(&layout, .CPE, 1)
	if c.channels >= 5 do add(&layout, .CPE, c.channels >= 7 ? 2 : 1)
	if c.channels == 6 || c.channels == 8 do add(&layout, .LFE, 0)
	return layout, .None
}

default_program_config :: proc(c: Config) -> (p: Program_Config, err: Error) {
	program := c.program_config
	if c.use_pce && program_config_present(&program) {
		_, err = program_channel_layout(&program)
		return c.program_config, err
	}
	layout, e := resolve_channel_layout(c)
	if e != .None do return {}, e
	p.object_type, p.sample_rate = 2, c.sample_rate
	for element, index in layout.elements[:layout.element_count] {
		if element.kind == .LFE {
			p.lfe[p.lfe_count] = element.tag; p.lfe_count += 1
		} else if index < (c.channels <= 2 ? 1 : (c.channels == 8 ? 3 : 2)) {
			p.front[p.front_count] = {element.kind == .CPE, element.tag}; p.front_count += 1
		} else if c.channels == 7 && index == 2 {
			p.side[p.side_count] = {element.kind == .CPE, element.tag}; p.side_count += 1
		} else {
			p.back[p.back_count] = {element.kind == .CPE, element.tag}; p.back_count += 1
		}
	}
	return p, .None
}

// An empty PCE permits a known-channel bootstrap; an in-band PCE replaces
// the inferred layout only when the decoder commits the complete access unit.
program_config_present :: proc(p: ^Program_Config) -> bool {
	return p != nil && p^ != Program_Config{}
}

program_channel_layout :: proc(p: ^Program_Config) -> (layout: Channel_Layout, err: Error) {
	if p == nil || sample_rate_index(p.sample_rate) < 0 do return {}, .Invalid_Config
	if p.object_type != 2 do return {}, .Unsupported_Profile
	// ISO/IEC 13818-7 7.1.2: AAC-LC programs cannot contain the separate
	// mono/stereo mixdown elements. Matrix mixdown metadata remains legal.
	if p.mono_mixdown_present || p.stereo_mixdown_present do return {}, .Invalid_Config
	if p.tag > 15 || p.front_count < 0 || p.side_count < 0 || p.back_count < 0 || p.lfe_count < 0 || p.associated_count < 0 || p.coupling_count < 0 || p.comment_bytes < 0 || p.comment_bytes > 255 do return {}, .Invalid_Config
	if p.lfe_count > 3 || p.associated_count > 7 || p.coupling_count > 15 || p.mono_mixdown_element > 15 || p.stereo_mixdown_element > 15 || p.matrix_mixdown_index > 3 do return {}, .Invalid_Config
	if p.front_count > 8 || p.side_count > 8 || p.back_count > 8 do return {}, .Unsupported_Channels
	for tag in p.associated[:p.associated_count] do if tag > 15 do return {}, .Invalid_Config
	seen: [4][16]bool
	for region in ([3][]Program_Element{p.front[:p.front_count], p.side[:p.side_count], p.back[:p.back_count]}) {
		for item in region {
			kind := item.is_pair ? Element_Kind.CPE : Element_Kind.SCE
			count := item.is_pair ? 2 : 1
			if item.tag > 15 || seen[kind][item.tag] do return {}, .Invalid_Config
			if layout.channels > MAX_CHANNELS - count || layout.element_count >= len(layout.elements) do return {}, .Unsupported_Channels
			seen[kind][item.tag] = true
			layout.elements[layout.element_count] = {kind, item.tag, layout.channels, count}
			layout.element_count += 1; layout.channels += count
		}
	}
	for tag in p.lfe[:p.lfe_count] {
		if tag > 15 || seen[Element_Kind.LFE][tag] do return {}, .Invalid_Config
		if layout.channels >= MAX_CHANNELS || layout.element_count >= len(layout.elements) do return {}, .Unsupported_Channels
		seen[Element_Kind.LFE][tag] = true
		layout.elements[layout.element_count] = {.LFE, tag, layout.channels, 1}
		layout.element_count += 1; layout.channels += 1
	}
	for item in p.coupling[:p.coupling_count] {
		if item.tag > 15 || seen[Element_Kind.CCE][item.tag] do return {}, .Invalid_Config
		seen[Element_Kind.CCE][item.tag] = true
	}
	if layout.channels == 0 do return {}, .Unsupported_Channels
	return layout, .None
}

// These own PCE syntax at the current bit position. Element ID_PCE belongs
// to the enclosing raw_data_block; byte alignment is relative to that block.
read_program_config_element :: proc(
	r: ^Bit_Reader,
	alignment_origin := 0,
) -> (
	p: Program_Config,
	err: Error,
) {
	if r == nil || alignment_origin < 0 || alignment_origin > r.pos do return {}, .Invalid_Config
	p.tag = u8(read_bits(r, 4)); p.object_type = u8(read_bits(r, 2)) + 1
	i := int(read_bits(r, 4))
	if i < len(SAMPLE_RATES) do p.sample_rate = SAMPLE_RATES[i]
	p.front_count = int(
		read_bits(r, 4),
	); p.side_count = int(read_bits(r, 4)); p.back_count = int(read_bits(r, 4))
	p.lfe_count = int(
		read_bits(r, 2),
	); p.associated_count = int(read_bits(r, 3)); p.coupling_count = int(read_bits(r, 4))
	p.mono_mixdown_present = read_flag(r)
	if p.mono_mixdown_present do p.mono_mixdown_element = u8(read_bits(r, 4))
	p.stereo_mixdown_present = read_flag(r)
	if p.stereo_mixdown_present do p.stereo_mixdown_element = u8(read_bits(r, 4))
	p.matrix_mixdown_present = read_flag(r)
	if p.matrix_mixdown_present {p.matrix_mixdown_index = u8(read_bits(r, 2)); p.pseudo_surround = read_flag(r)}
	for region in 0 ..< 3 {
		count := region == 0 ? p.front_count : (region == 1 ? p.side_count : p.back_count)
		for j in 0 ..< count {
			item := Program_Element{read_flag(r), u8(read_bits(r, 4))}
			if j < MAX_CHANNELS {
				if region ==
				   0 {p.front[j] = item} else if region == 1 {p.side[j] = item} else {p.back[j] = item}
			}
		}
	}
	for j in 0 ..< p.lfe_count do p.lfe[j] = u8(read_bits(r, 4))
	for j in 0 ..< p.associated_count do p.associated[j] = u8(read_bits(r, 4))
	for j in 0 ..< p.coupling_count do p.coupling[j] = {read_flag(r), u8(read_bits(r, 4))}
	skip_bits(r, -(r.pos - alignment_origin) & 7)
	p.comment_bytes = int(read_bits(r, 8))
	for j in 0 ..< p.comment_bytes do p.comment[j] = u8(read_bits(r, 8))
	if r.err != .None do return {}, r.err
	_, err = program_channel_layout(&p)
	return
}

write_program_config_element :: proc(
	w: ^common.Bit_Writer,
	p: ^Program_Config,
	alignment_origin := 0,
) -> Error {
	if _, err := program_channel_layout(p); err != .None do return err
	if w == nil || w.buf == nil || alignment_origin < 0 || alignment_origin > common.bits_written(w) do return .Invalid_Config
	// Reserve the complete bounded syntax before the shared writer publishes
	// bytes. Its append operations then cannot allocate or partially fail.
	bits :=
		34 +
		(p.mono_mixdown_present ? 4 : 0) +
		(p.stereo_mixdown_present ? 4 : 0) +
		(p.matrix_mixdown_present ? 3 : 0)
	bits +=
		5 * (p.front_count + p.side_count + p.back_count + p.coupling_count) +
		4 * (p.lfe_count + p.associated_count) +
		7 +
		8 +
		8 * p.comment_bytes
	if err := reserve_writer_bits(w, bits); err != .None do return err
	common.write_bits(w, u32(p.tag), 4); common.write_bits(w, u32(p.object_type - 1), 2)
	common.write_bits(w, u32(sample_rate_index(p.sample_rate)), 4)
	common.write_bits(
		w,
		u32(p.front_count),
		4,
	); common.write_bits(w, u32(p.side_count), 4); common.write_bits(w, u32(p.back_count), 4)
	common.write_bits(
		w,
		u32(p.lfe_count),
		2,
	); common.write_bits(w, u32(p.associated_count), 3); common.write_bits(w, u32(p.coupling_count), 4)
	common.write_bits(w, u32(p.mono_mixdown_present), 1)
	if p.mono_mixdown_present do common.write_bits(w, u32(p.mono_mixdown_element), 4)
	common.write_bits(w, u32(p.stereo_mixdown_present), 1)
	if p.stereo_mixdown_present do common.write_bits(w, u32(p.stereo_mixdown_element), 4)
	common.write_bits(w, u32(p.matrix_mixdown_present), 1)
	if p.matrix_mixdown_present {common.write_bits(w, u32(p.matrix_mixdown_index), 2); common.write_bits(w, u32(p.pseudo_surround), 1)}
	for region in ([3][]Program_Element{p.front[:p.front_count], p.side[:p.side_count], p.back[:p.back_count]}) do for item in region {
		common.write_bits(w, u32(item.is_pair), 1); common.write_bits(w, u32(item.tag), 4)
	}
	for tag in p.lfe[:p.lfe_count] do common.write_bits(w, u32(tag), 4)
	for tag in p.associated[:p.associated_count] do common.write_bits(w, u32(tag), 4)
	for item in p.coupling[:p.coupling_count] {common.write_bits(w, u32(item.independent), 1); common.write_bits(w, u32(item.tag), 4)}
	common.write_bits(
		w,
		0,
		-(common.bits_written(w) - alignment_origin) & 7,
	); common.write_bits(w, u32(p.comment_bytes), 8)
	for b in p.comment[:p.comment_bytes] do common.write_bits(w, u32(b), 8)
	return .None
}
