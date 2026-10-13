// Pack sampled decoder planes into a transfer buffer. Each invocation owns a
// complete word; row padding keeps NV12 widths such as 386 free of write races.
[[vk::binding(0, 0)]] Texture2D<float> source_y;
[[vk::binding(1, 0)]] Texture2D<float2> source_uv;
[[vk::binding(2, 0)]] RWByteAddressBuffer destination;

struct Parameters { uint width, height, depth, crop_x, crop_y, row_pitch; };
[[vk::push_constant]] ConstantBuffer<Parameters> parameters;

uint stored_value(float value) {
    // R16 plane views expose P010's left-aligned sample, including six zero bits.
    return uint(round(value * (parameters.depth == 10 ? 65535.0 : 255.0)));
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= parameters.row_pitch / 4 || id.y >= parameters.height) return;
    uint bits = parameters.depth == 10 ? 16 : 8;
    uint samples = 32 / bits;
    uint y_word = 0;
    for (uint i = 0; i < samples; ++i) {
        uint x = id.x * samples + i;
        if (x < parameters.width) {
            float value = source_y.Load(int3(x + parameters.crop_x, id.y + parameters.crop_y, 0));
            y_word |= stored_value(value) << (i * bits);
        }
    }
    destination.Store(id.y * parameters.row_pitch + id.x * 4, y_word);
    if (id.y >= parameters.height / 2) return;
    uint uv_word = 0;
    for (uint i = 0; i < samples / 2; ++i) {
        uint x = id.x * (samples / 2) + i;
        if (x < parameters.width / 2) {
            float2 value = source_uv.Load(int3(x + parameters.crop_x / 2, id.y + parameters.crop_y / 2, 0));
            uv_word |= stored_value(value.x) << (i * bits * 2);
            uv_word |= stored_value(value.y) << ((i * 2 + 1) * bits);
        }
    }
    destination.Store(parameters.height * parameters.row_pitch + id.y * parameters.row_pitch + id.x * 4, uv_word);
}
