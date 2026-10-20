-- Every number on screen, with where it comes from. Paths are in the odecs
-- repository (../); nothing here is estimated or measured for this video.

local M = {}

-- movie/README.md, "Performance": reading alpha video at 1920x1080,
-- frames through RGBA including conversion, file input; 1 and 8 threads.
M.MOVIE_SRC = "odecs movie/README.md · Performance · 1920×1080 through RGBA, file input"
M.PRORES = { "ProRes 4444 + alpha", "88 fps", "322 fps" }
M.VP9 = { "VP9 + alpha stream", "72 fps", "183 fps" }

-- webp/README.md: the 11158x2156 lossy corpus image on one core
-- against libwebp 1.6.0 (WebPDecodeRGBA, -O3, its SIMD code), and the
-- corpus gate (all 131 files RGBA-identical to dwebp).
M.WEBP_SRC = "odecs webp/README.md · one core, against libwebp 1.6.0 with its SSE2/SSE4.1/AVX2 code"
M.WEBP_SIZE = "11158 × 2156"
M.WEBP_OURS, M.WEBP_LIBWEBP = "223 ms", "162 ms"
M.WEBP_CORPUS = 131

-- The three charts, ms per 1080p frame (lower is better) or fps:
--   media/vulkan/README.md: movie.Reader on the RX 9070 XT, best of five,
--     one picture at a time against three in flight;
--   media/vulkan/README.md: 900 1080p I420 frames through movie.Writer on an
--     RX 9070 XT (tests/movie_encode_timing.odin), before and after three
--     pictures in flight;
--   h264/README.md: the native encoder, 1080p, 16 slices on 16
--     workers (Ryzen 9 9900X3D), against x264 medium with the same tools.
M.CHARTS = {
  { title = "VULKAN VIDEO DECODE", unit = "ms / frame", from = "one picture at a time", to = "three in flight",
    src = "odecs media/vulkan/README.md · movie.Reader, RX 9070 XT, best of five",
    rows = { { "1080p H.264, B-frames", 2.45, 1.05 }, { "1080p H.265", 2.36, 1.00 }, { "720p 10-bit AV1", 2.33, 0.82 } } },
  { title = "VULKAN VIDEO ENCODE", unit = "ms / frame", from = "before", to = "three in flight",
    src = "odecs media/vulkan/README.md · 900 1080p frames through movie.Writer, RX 9070 XT",
    rows = { { "H.264", 3.64, 2.01 }, { "H.265 (HEVC)", 3.59, 1.56 } } },
  { title = "POOLED NATIVE H.264 ENCODER", unit = "fps", fps = true,
    src = "odecs h264/README.md · 1080p, 16 slices on 16 workers, Ryzen 9 9900X3D",
    rows = { { "odecs native, QP 26", 144 }, { "x264 medium, same tools", 221 } } },
}

return M
