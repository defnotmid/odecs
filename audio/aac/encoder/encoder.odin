package aac_encoder

import aac ".."
import common "../../../common"
import "core:math"

Config :: aac.Config
Error :: aac.Error
FRAME_SAMPLES :: aac.FRAME_SAMPLES
// Presentation delay is one transform frame (960 or1024), independent of
// the additional one-frame input lookahead. ADTS has no gapless metadata.
ENCODER_DELAY :: 1024
Transport :: enum {
	ADTS,
	Raw,
	LOAS,
}
Options :: struct {
	disable_short_windows,
	disable_ms,
	disable_intensity,
	disable_tns,
	disable_pns,
	disable_reservoir: bool,
	constant_bit_rate:                                                                                 bool,
	window_shape:                                                                                      u8, //0 sine,1 KBD; both shapes share the same filterbank owner.
}
Frame_Stats :: struct {
	sequence:                                                                                          aac.Window_Sequence,
	bytes,
	target_bits,
	reservoir_bits,
	adjustment,
	ms_bands,
	intensity_bands,
	pns_bands,
	tns_filters: int,
}
Tns_Filter :: struct {
	start_band, order: int,
	coefficient:       [4]i8,
	prediction:        [5]f64,
}
Encoder :: struct {
	config:                                                                                                              Config,
	options:                                                                                                             Options,
	transport:                                                                                                           Transport,
	layout:                                                                                                              aac.Channel_Layout,
	lfe:                                                                                                                 [aac.MAX_CHANNELS]bool,
	lfe_max_sfb:                                                                                                         int,
	program:                                                                                                             aac.Program_Config,
	rate_index,
	frame_samples,
	frames,
	input_frames,
	independent_channels:                                               int,
	initialized,
	finished,
	pending_valid,
	pending_attack,
	pending_late_attack: bool,
	sequence:                                                                                                            aac.Window_Sequence,
	previous_shape:                                                                                                      u8,
	transform:                                                                                                           aac.Transform,
	previous,
	pending,
	spectrum,
	companded:                                                                              [aac.MAX_CHANNELS][1024]f64,
	quant:                                                                                                               [aac.MAX_CHANNELS][1024]i32,
	negative:                                                                                                            [aac.MAX_CHANNELS][1024]bool,
	band_start:                                                                                                          [8][64]int,
	global_gain:                                                                                                         [aac.MAX_CHANNELS]int,
	coded_max_sfb:                                                                                                       [aac.MAX_CHANNELS]int,
	spectral_bits:                                                                                                       [aac.MAX_CHANNELS][8][64]int,
	quant_factor:                                                                                                        [256]f64,
	tns_reflection:                                                                                                      [16]f64,
	base_sf,
	sf:                                                                                                         [aac.MAX_CHANNELS][8][64]int,
	tool,
	codebook:                                                                                                      [aac.MAX_CHANNELS][8][64]u8,
	energy,
	threshold:                                                                                                   [aac.MAX_CHANNELS][8][64]f64,
	ms:                                                                                                                  [aac.MAX_CHANNELS][8][64]bool,
	tns:                                                                                                                 [aac.MAX_CHANNELS][8]Tns_Filter,
	input_energy:                                                                                                        [aac.MAX_CHANNELS]f64,
	input_tail:                                                                                                          [aac.MAX_CHANNELS]f64,
	groups,
	max_sfb,
	stride:                                                                                             int,
	group_length,
	group_start:                                                                                           [8]int,
	long_max_sfb,
	short_max_sfb:                                                                                         int,
	long_spread:                                                                                                         [64][64]f64,
	short_spread:                                                                                                        [64][64]f64,
	time:                                                                                                                [2048]f64,
	reservoir_bits,
	reservoir_limit,
	rate_remainder:                                                                     int,
	stats,
	work_stats:                                                                                                   Frame_Stats,
	payload,
	packet:                                                                                                     [dynamic]u8,
	pce_prefix:                                                                                                          [512]u8,
	pce_bytes,
	first_transport_bits,
	next_transport_bits,
	prepared_rate_remainder,
	prepared_reservoir_bits,
	flush_stage: int,
	latm_config_sent:                                                                                                    bool,
}

encoder_delay :: proc(e: ^Encoder) -> int {return e.frame_samples}

init_encoder :: proc(
	e: ^Encoder,
	config: Config,
	transport: Transport = .ADTS,
	options: Options = {},
) -> Error {
	if e == nil do return .Invalid_State
	if e.initialized do return .Invalid_State
	if err := aac.validate_config(config); err != .None do return err
	cfg := config
	cfg.frame_samples = aac.resolved_frame_samples(cfg)
	if options.window_shape > 1 do return .Invalid_Config
	if transport == .ADTS && cfg.frame_samples != 1024 do return .Unsupported_Transport
	if cfg.bit_rate == 0 do cfg.bit_rate = 64000 * cfg.channels
	if cfg.bit_rate < 8000 * cfg.channels || cfg.bit_rate > min(512000 * cfg.channels, cfg.sample_rate * 6 * cfg.channels) do return .Invalid_Config
	layout, err := aac.resolve_channel_layout(cfg)
	if err != .None do return err
	independent := 0
	for element in layout.elements[:layout.element_count] do if element.kind != .LFE do independent += element.channels
	if independent == 0 || cfg.bit_rate > cfg.sample_rate * 6 * independent do return .Invalid_Config
	program, pe := aac.default_program_config(cfg)
	if pe != .None do return pe
	e^ = {
		config               = cfg,
		options              = options,
		transport            = transport,
		layout               = layout,
		program              = program,
		rate_index           = aac.sample_rate_index(cfg.sample_rate),
		frame_samples        = cfg.frame_samples,
		independent_channels = independent,
	}
	aac.init_transform(&e.transform, e.frame_samples)
	e.payload = make([dynamic]u8, 0, 65536)
	if raw_data(e.payload) == nil {e^ = {}; return .Allocation_Failed}
	e.packet = make([dynamic]u8, 0, 65536)
	if raw_data(e.packet) == nil {delete(e.payload); e^ = {}; return .Allocation_Failed}
	for sf in 0 ..< 256 do e.quant_factor[sf] = math.pow(2.0, -3 * f64(sf - 100) / 16)
	for q in -8 ..= 7 do e.tns_reflection[q + 8] = math.sin(f64(q) * (math.PI / 2) / (q < 0 ? 8.5 : 7.5))
	bandwidth := min(
		f64(cfg.sample_rate) / 2,
		min(20000.0, max(4000.0, f64(cfg.bit_rate / cfg.channels) * 0.26)),
	)
	e.long_max_sfb = bandwidth_bands(
		aac.long_offsets(e.rate_index, e.frame_samples),
		e.frame_samples,
		cfg.sample_rate,
		bandwidth,
	)
	e.short_max_sfb = bandwidth_bands(
		aac.short_offsets(e.rate_index, e.frame_samples),
		e.frame_samples / 8,
		cfg.sample_rate,
		bandwidth,
	)
	offsets := aac.long_offsets(e.rate_index, e.frame_samples)
	for i in 1 ..< len(offsets) do if offsets[i] >= 12 {e.lfe_max_sfb = i; break}
	for element in layout.elements[:layout.element_count] do if element.kind == .LFE do e.lfe[element.first_channel] = true
	initialize_spreading(e)
	nominal := cfg.bit_rate * e.frame_samples / cfg.sample_rate
	e.reservoir_limit = max(0, min(6144 * independent, 65528) - nominal)
	if aac.channel_configuration(cfg) == 0 {
		writer := common.init_bit_writer(&e.payload)
		common.write_bits(&writer, 5, 3)
		if error := aac.write_program_config_element(&writer, &e.program);
		   error != .None {destroy_encoder(e); return error}
		assert(writer.nbits == 0 && len(e.payload) <= len(e.pce_prefix))
		e.pce_bytes = len(e.payload); copy(e.pce_prefix[:], e.payload[:]); clear(&e.payload)
	}
	switch transport {
	case .ADTS:
		e.first_transport_bits = 56; e.next_transport_bits = 56
	case .Raw:
	case .LOAS:
		dummy := [1]u8{0xe0}
		if error := aac.append_loas(&e.packet, cfg, dummy[:]);
		   error != .None {destroy_encoder(e); return error}
		e.first_transport_bits = (len(e.packet) - 1) * 8
		clear(&e.packet)
		if error := aac.append_loas(&e.packet, cfg, dummy[:], true);
		   error != .None {destroy_encoder(e); return error}
		e.next_transport_bits = (len(e.packet) - 1) * 8; clear(&e.packet)
	}
	e.initialized = true
	return .None
}

destroy_encoder :: proc(e: ^Encoder) {if e == nil do return; delete(e.payload); delete(e.packet)
	e^ = {}}
reset_encoder :: proc(e: ^Encoder) {
	if e == nil do return
	e.previous = {}; e.pending = {}; e.input_energy = {}; e.input_tail = {}
	e.pending_valid =
		false; e.pending_attack = false; e.pending_late_attack = false; e.frames = 0; e.input_frames = 0; e.finished = false
	e.sequence = .Long; e.previous_shape = 0; e.reservoir_bits = 0; e.rate_remainder = 0; e.stats = {}
	e.latm_config_sent = false; clear(&e.payload)
	clear(&e.packet); e.flush_stage = 0
}

@(private)
write_huffman :: proc(w: ^common.Bit_Writer, book, symbol: int) {
	c := aac.CODEBOOKS[book][symbol]
	common.write_bits(w, c.bits, int(c.length))
}

@(private)
tuple_code :: proc(book: int, values: []i32) -> (index, cost: int) {
	signed := book <= 2 || book == 5 || book == 6
	radix := book <= 4 ? 3 : (book <= 6 ? 9 : (book <= 8 ? 8 : (book <= 10 ? 13 : 17)))
	max_value := signed ? radix / 2 : radix - 1
	for v in values {
		mag := int(abs(v))
		if book != 11 && mag > max_value do return 0, 1 << 20
		digit := signed ? int(v) + max_value : min(mag, max_value)
		index = index * radix + digit
		if !signed && v != 0 do cost += 1
		if book == 11 && mag >= 16 {
			n := 4
			for mag >= 1 << uint(n + 1) do n += 1
			cost += 2 * n - 3
		}
	}
	cost += int(aac.CODEBOOKS[book][index].length)
	return
}

@(private)
write_tuple :: proc(w: ^common.Bit_Writer, book: int, values: []i32) {
	signed := book <= 2 || book == 5 || book == 6
	radix := book <= 4 ? 3 : (book <= 6 ? 9 : (book <= 8 ? 8 : (book <= 10 ? 13 : 17)))
	index := 0
	for value in values do index = index * radix + (signed ? int(value) + radix / 2 : min(int(abs(value)), radix - 1))
	write_huffman(w, book, index)
	if !signed do for v in values do if v != 0 do common.write_bits(w, v < 0 ? 1 : 0, 1)
	if book == 11 do for value in values do if abs(value) >= 16 {
		v := abs(value)
		n := 4
		for v >= i32(1) << uint(n + 1) {common.write_bits(w, 1, 1); n += 1}
		common.write_bits(w, 0, 1)
		common.write_bits(w, u32(v - (i32(1) << uint(n))), n)
	}
}

@(private)
paired_codebook_cost :: proc(
	$Radix: int,
	$Signed: bool,
	$Count: int,
	values: []i32,
	first_book, limit: int,
) -> (
	first, second: int,
) {
	codes_first := aac.CODEBOOKS[first_book]
	codes_second := aac.CODEBOOKS[first_book + 1]
	for k := 0; k < len(values); k += Count {
		// Nonnegative tuple costs cannot recover after reaching the incumbent.
		if first >= limit && second >= limit do break
		index, extra := 0, 0
		for i in 0 ..< Count {
			v := values[k + i]
			digit := Signed ? int(v) + Radix / 2 : int(abs(v))
			index = index * Radix + digit
			if !Signed && v != 0 do extra += 1
		}
		if first < limit do first += int(codes_first[index].length) + extra
		if second < limit do second += int(codes_second[index].length) + extra
	}
	return
}

@(private)
choose_codebook_and_cost :: proc(values: []i32, maximum: int) -> (book: u8, bits: int) {
	// The quantizer supplies this exact magnitude bound. Long-band widths are
	// multiples of four, and the saturation limit is 8191.
	assert(len(values) > 0 && len(values) <= 1024 && len(values) % 4 == 0)
	assert(maximum >= 0 && maximum <= 8191)
	best, best_cost := 11, max(int)
	for pair in 0 ..< 5 {
		first, second: int
		// Each pair shares tuple digits and sign costs, differing only in code
		// lengths. A band exceeding a pair's alphabet cannot use either book:
		// its invalid-tuple sentinel exceeds the entire valid book-11 cost.
		switch pair {
		case 0:
			if maximum > 1 do continue
			first, second = paired_codebook_cost(3, true, 4, values, 1, best_cost)
		case 1:
			if maximum > 2 do continue
			first, second = paired_codebook_cost(3, false, 4, values, 3, best_cost)
		case 2:
			if maximum > 4 do continue
			first, second = paired_codebook_cost(9, true, 2, values, 5, best_cost)
		case 3:
			if maximum > 7 do continue
			first, second = paired_codebook_cost(8, false, 2, values, 7, best_cost)
		case 4:
			if maximum > 12 do continue
			first, second = paired_codebook_cost(13, false, 2, values, 9, best_cost)
		}
		// Compare in the original ascending book order, preserving strict ties.
		book := pair * 2 + 1
		if first < best_cost {best, best_cost = book, first}
		if second < best_cost {best, best_cost = book + 1, second}
	}
	cost := 0
	for k := 0; k < len(values); k += 2 {
		_, code_bits := tuple_code(11, values[k:k + 2])
		cost += code_bits
		if cost >= best_cost do break
	}
	if cost < best_cost {best = 11; best_cost = cost}
	return u8(best), best_cost
}

@(private)
choose_codebook :: proc(values: []i32, maximum: int) -> u8 {book, _ := choose_codebook_and_cost(
		values,
		maximum,
	)
	return book}
