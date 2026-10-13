// Integration gate for GPU-resident Vulkan Video output. Read the separate
// sampled Y/UV plane views and preserve every sample in a planar uint buffer.
[[vk::binding(0, 0)]] Texture2D<float> source_y;
[[vk::binding(1, 0)]] Texture2D<float2> source_uv;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint> destination;

struct Parameters { uint width, height, depth, crop_x, crop_y; };
[[vk::push_constant]] ConstantBuffer<Parameters> parameters;

uint sample_value(float value) {
    return parameters.depth == 10 ? uint(round(value * 65535.0)) >> 6 : uint(round(value * 255.0));
}

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= parameters.width || id.y >= parameters.height) return;
    float y = source_y.Load(int3(id.x + parameters.crop_x, id.y + parameters.crop_y, 0));
    destination[id.y * parameters.width + id.x] = sample_value(y);
    uint cw = parameters.width / 2;
    uint ch = parameters.height / 2;
    if (id.x < cw && id.y < ch) {
        float2 uv = source_uv.Load(int3(id.x + parameters.crop_x / 2, id.y + parameters.crop_y / 2, 0));
        uint index = id.y * cw + id.x;
        destination[parameters.width * parameters.height + index] = sample_value(uv.x);
        destination[parameters.width * parameters.height + cw * ch + index] = sample_value(uv.y);
    }
}
