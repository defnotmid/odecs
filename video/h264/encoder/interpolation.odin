package h264_encoder

import h264 ".."

import "base:intrinsics"
import "core:slice"

// Each immutable reference owns its three half-sample planes. Motion search
// then reads pixels or averages two planes, independent of the number of trials.
Reference_Interpolation :: struct {
	storage:                                       []u8,
	horizontal_half, vertical_half, diagonal_half: [^]u8,
}

init_reference_interpolation :: proc(
	picture: ^Encoder_Picture,
	allocator := context.allocator,
) -> Error {
	stride := picture.buf.y_stride
	plane_size := stride * (picture.buf.coded_height + 2 * h264.PADDING_LENGTH)
	visible_origin := h264.PADDING_LENGTH * (stride + 1)
	storage := make([]u8, plane_size * 3, allocator)
	if raw_data(storage) == nil do return .Allocation_Failed
	picture.interpolation = {
		storage,
		&storage[visible_origin],
		&storage[plane_size + visible_origin],
		&storage[2 * plane_size + visible_origin],
	}
	return .None
}

// Existing slice ownership also partitions this uniform reference preparation.
// The two-pixel leading and three-pixel trailing tap margins match the motion
// predictor's clamped source coordinates.
prepare_reference_interpolation_range :: proc(data: rawptr, first, end: int) {
	for &task in slice.from_ptr(cast([^]Slice_Task)data, end)[first:end] {
		picture := task.state.curr
		buffer := &picture.buf
		planes := &picture.interpolation
		first_row := task.first_macroblock / task.grid.macroblock_columns * 16
		end_row :=
			(task.first_macroblock + task.macroblock_count) / task.grid.macroblock_columns * 16
		if first_row == 0 do first_row = 2 - h264.PADDING_LENGTH
		if end_row == buffer.coded_height do end_row += h264.PADDING_LENGTH - 3
		first_column := 2 - h264.PADDING_LENGTH
		end_column := buffer.coded_width + h264.PADDING_LENGTH - 3
		stride := buffer.y_stride
		for row := first_row; row < end_row; row += 16 {
			height := min(16, end_row - row)
			for column := first_column; column < end_column; column += 16 {
				width := min(16, end_column - column)
				offset := row * stride + column
				if width == 16 {
					h264.mc_luma_lanes(
						16,
						&buffer.y[offset],
						stride,
						&planes.horizontal_half[offset],
						stride,
						2,
						0,
						height,
					)
					h264.mc_luma_lanes(
						16,
						&buffer.y[offset],
						stride,
						&planes.vertical_half[offset],
						stride,
						0,
						2,
						height,
					)
					h264.mc_luma_lanes(
						16,
						&buffer.y[offset],
						stride,
						&planes.diagonal_half[offset],
						stride,
						2,
						2,
						height,
					)
				} else {
					h264.mc_luma(
						&buffer.y[offset],
						stride,
						&planes.horizontal_half[offset],
						stride,
						2,
						0,
						width,
						height,
					)
					h264.mc_luma(
						&buffer.y[offset],
						stride,
						&planes.vertical_half[offset],
						stride,
						0,
						2,
						width,
						height,
					)
					h264.mc_luma(
						&buffer.y[offset],
						stride,
						&planes.diagonal_half[offset],
						stride,
						2,
						2,
						width,
						height,
					)
				}
			}
			// Odd quarter-sample positions also use the next vertical-half column.
			offset := row * stride + end_column
			h264.mc_luma(
				&buffer.y[offset],
				stride,
				&planes.vertical_half[offset],
				stride,
				0,
				2,
				1,
				height,
			)
		}
		// The final slice owns the extra horizontal-half row for odd quarter samples.
		if end_row == buffer.coded_height + h264.PADDING_LENGTH - 3 {
			for column := first_column; column < end_column; column += 16 {
				width := min(16, end_column - column)
				offset := end_row * stride + column
				h264.mc_luma(
					&buffer.y[offset],
					stride,
					&planes.horizontal_half[offset],
					stride,
					2,
					0,
					width,
					1,
				)
			}
		}
	}
}

predict_reference_luma :: proc(
	reference: ^Encoder_Picture,
	column, row, width, height: int,
	motion: [2]i16,
	destination: [^]u8,
) {
	buffer := &reference.buf
	x := clamp(
		column + int(motion[0] >> 2),
		2 - h264.PADDING_LENGTH,
		buffer.coded_width + h264.PADDING_LENGTH - width - 3,
	)
	y := clamp(
		row + int(motion[1] >> 2),
		2 - h264.PADDING_LENGTH,
		buffer.coded_height + h264.PADDING_LENGTH - height - 3,
	)
	horizontal_fraction, vertical_fraction := int(motion[0] & 3), int(motion[1] & 3)
	offset := y * buffer.y_stride + x
	integer: [^]u8 = &buffer.y[offset]
	horizontal: [^]u8 = &reference.interpolation.horizontal_half[offset]
	vertical: [^]u8 = &reference.interpolation.vertical_half[offset]
	diagonal: [^]u8 = &reference.interpolation.diagonal_half[offset]
	first, second: [^]u8
	switch {
	case horizontal_fraction == 0 && vertical_fraction == 0:
		first = integer
	case horizontal_fraction == 2 && vertical_fraction == 0:
		first = horizontal
	case horizontal_fraction == 0 && vertical_fraction == 2:
		first = vertical
	case horizontal_fraction == 2 && vertical_fraction == 2:
		first = diagonal
	case vertical_fraction == 0:
		first, second = horizontal, &integer[horizontal_fraction >> 1]
	case horizontal_fraction == 0:
		first, second = vertical, &integer[(vertical_fraction >> 1) * buffer.y_stride]
	case horizontal_fraction == 2:
		first, second = diagonal, &horizontal[(vertical_fraction >> 1) * buffer.y_stride]
	case vertical_fraction == 2:
		first, second = diagonal, &vertical[horizontal_fraction >> 1]
	case:
		first, second =
			&horizontal[(vertical_fraction >> 1) * buffer.y_stride],
			&vertical[horizontal_fraction >> 1]
	}
	switch width {
	case 16:
		copy_reference_prediction(16, first, second, buffer.y_stride, destination, height)
	case 8:
		copy_reference_prediction(8, first, second, buffer.y_stride, destination, height)
	case:
		copy_reference_prediction(4, first, second, buffer.y_stride, destination, height)
	}
}

copy_reference_prediction :: proc(
	$Width: int,
	first, second: [^]u8,
	source_stride: int,
	destination: [^]u8,
	height: int,
) #no_bounds_check {
	for row in 0 ..< height {
		prediction := h264.load_lanes(Width, &first[row * source_stride])
		if second != nil do prediction = h264.average_lanes(prediction, h264.load_lanes(Width, &second[row * source_stride]))
		intrinsics.unaligned_store(
			(^#simd[Width]u8)(&destination[row * 16]),
			(#simd[Width]u8)(prediction),
		)
	}
}
