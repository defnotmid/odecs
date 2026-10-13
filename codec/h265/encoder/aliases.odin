package h265_encoder

import hevc ".."

// Shared primitives re-exported under their original names so the encoder
// sources read exactly as they did before the encoder/decoder split.
Plane :: hevc.Plane
Frame :: hevc.Frame
Sample :: hevc.Sample
Nal_Type :: hevc.Nal_Type
Slice_Type :: hevc.Slice_Type
Color :: hevc.Color
Scan_Order :: hevc.Scan_Order
Chroma_Format :: hevc.Chroma_Format
Scaling_List :: hevc.Scaling_List

at :: hevc.at
set_at :: hevc.set_at
alloc_frame :: hevc.alloc_frame
free_frame :: hevc.free_frame
fill_frame :: hevc.fill_frame
log2_size :: hevc.log2_size
// forward_transform lives in simd.odin (transposed-basis vector kernel);
// inverse_transform is the shared scalar path.
inverse_transform :: hevc.inverse_transform
inverse_transform_dst4 :: hevc.inverse_transform_dst4
transform_skip :: hevc.transform_skip
inverse_transform_skip :: hevc.inverse_transform_skip
forward_rdpcm :: hevc.forward_rdpcm
inverse_rdpcm :: hevc.inverse_rdpcm
chroma_qp :: hevc.chroma_qp
quantize :: hevc.quantize
dequantize :: hevc.dequantize
scan_table :: hevc.scan_table
