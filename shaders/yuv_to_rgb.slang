// YUV420p to RGBA Color Conversion Compute Shader
// Converts planar H.264 YUV (4:2:0 subsampled) directly to RGBA on GPU for Vulkan/Metal presentation.

[[vk::binding(0, 0)]] ByteAddressBuffer y_plane  : register(t0, space0);
[[vk::binding(1, 0)]] ByteAddressBuffer u_plane  : register(t1, space0);
[[vk::binding(2, 0)]] ByteAddressBuffer v_plane  : register(t2, space0);
[[vk::binding(3, 0)]] RWTexture2D<float4> out_rgba : register(u0, space0);

struct Params {
    uint width;
    uint height;
    uint y_stride;
    uint uv_stride;
};

[[vk::binding(0, 1)]] ConstantBuffer<Params> u : register(b0, space1);

// Standard ITU-R BT.601 Studio Range YUV to sRGB conversion
float3 yuv_bt601_to_rgb(float y, float u_val, float v_val) {
    float y_sub = max(0.0, y - (16.0 / 255.0));
    float c = 1.164383 * y_sub;
    float d = u_val - (128.0 / 255.0);
    float e = v_val - (128.0 / 255.0);

    float r = c + 1.596027 * e;
    float g = c - 0.391762 * d - 0.812968 * e;
    float b = c + 2.017232 * d;

    return saturate(float3(r, g, b));
}

[shader("compute")]
[numthreads(16, 16, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= u.width || id.y >= u.height) return;

    // Load Y sample (1 byte at y_stride * y + x)
    uint y_offset = id.y * u.y_stride + id.x;
    uint y_word = y_plane.Load(y_offset & ~3u);
    uint y_byte = (y_word >> ((y_offset & 3u) * 8u)) & 0xFFu;
    float y_val = float(y_byte) / 255.0;

    // Load U and V samples (subsampled 2:1 horizontally and vertically)
    uint uv_x = id.x >> 1u;
    uint uv_y = id.y >> 1u;
    uint uv_offset = uv_y * u.uv_stride + uv_x;

    uint u_word = u_plane.Load(uv_offset & ~3u);
    uint u_byte = (u_word >> ((uv_offset & 3u) * 8u)) & 0xFFu;
    float u_val = float(u_byte) / 255.0;

    uint v_word = v_plane.Load(uv_offset & ~3u);
    uint v_byte = (v_word >> ((uv_offset & 3u) * 8u)) & 0xFFu;
    float v_val = float(v_byte) / 255.0;

    float3 rgb = yuv_bt601_to_rgb(y_val, u_val, v_val);
    out_rgba[id.xy] = float4(rgb, 1.0);
}
