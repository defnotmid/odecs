-- Every measured number on screen comes from oicut's BENCHMARKS.tsv (../),
-- which `bash tests/compare.sh run` writes and BENCHMARKS.md shows; nothing
-- here is estimated or measured for this video. A missing row is an error
-- that names the case to run.

local rows = {}
local fh = assert(io.open(SCRIPT_DIR .. "/../BENCHMARKS.tsv"))
for line in fh:lines() do
  local id, _, oicut, reference, _, _, _, _, _, machine = line:match(("([^\t]*)\t"):rep(9) .. "([^\t]*)")
  if id and id ~= "id" then rows[id] = { oicut = tonumber(oicut), reference = tonumber(reference), machine = machine } end
end
fh:close()

local function bench(id)
  return assert(rows[id], "BENCHMARKS.tsv has no " .. id .. ": bash tests/compare.sh run " .. id:match("^[^/]+/[^/]+"))
end
local function whole(v) return math.floor(v + 0.5) end

local M = {}

-- alpha/: tests/movie_alpha.odin through video.Reader, frames through RGBA
-- including conversion, file input; 1 and 8 threads.
local prores, prores8 = bench("alpha/prores4444/fps-1t"), bench("alpha/prores4444/fps-8t")
local vp9, vp98 = bench("alpha/vp9-alpha/fps-1t"), bench("alpha/vp9-alpha/fps-8t")
M.MOVIE_SRC = "oicut BENCHMARKS.md · alpha video · 1920×1080 through RGBA, file input · " .. prores.machine
M.PRORES = { "ProRes 4444 + alpha", whole(prores.oicut) .. " fps", whole(prores8.oicut) .. " fps" }
M.VP9 = { "VP9 + alpha stream", whole(vp9.oicut) .. " fps", whole(vp98.oicut) .. " fps" }

-- decode/webp-bryce: the 11158x2156 lossy corpus image on one core against
-- libwebp 1.6.0 (WebPDecodeRGBA, -O3, its SIMD code); the corpus gate
-- (tests/webp_check.sh: all 131 files RGBA-identical to dwebp).
local webp = bench("decode/webp-bryce")
M.WEBP_SRC = "oicut BENCHMARKS.md · one core, against libwebp 1.6.0 with its SSE2/SSE4.1/AVX2 code"
M.WEBP_SIZE = "11158 × 2156"
M.WEBP_OURS, M.WEBP_LIBWEBP = whole(webp.oicut) .. " ms", whole(webp.reference) .. " ms"
M.WEBP_CORPUS = 131

-- The three charts, ms per frame (lower is better) or fps:
--   gpu/decode-*: video.Reader planar, one picture in flight against three;
--   gpu/encode-*: 900 1080p I420 frames through video.Writer, the same;
--   encode/h264-16: the native encoder, 1080p, 16 slices on 16 workers,
--     against x264 medium with the same tools.
local function depths(kind, codec, label)
  return { label, bench("gpu/" .. kind .. "-" .. codec .. "/depth1").oicut, bench("gpu/" .. kind .. "-" .. codec .. "/depth3").oicut }
end
local gpu = bench("gpu/decode-h264/depth3").machine
local h264 = bench("encode/h264-16/speed")
M.CHARTS = {
  { title = "VULKAN VIDEO DECODE", unit = "ms / frame", from = "one picture at a time", to = "three in flight",
    src = "oicut BENCHMARKS.md · video.Reader · " .. gpu,
    rows = { depths("decode", "h264", "1080p H.264, B-frames"), depths("decode", "h265", "1080p H.265"),
      depths("decode", "av1", "720p 10-bit AV1") } },
  { title = "VULKAN VIDEO ENCODE", unit = "ms / frame", from = "one picture at a time", to = "three in flight",
    src = "oicut BENCHMARKS.md · 900 1080p frames through video.Writer · " .. gpu,
    rows = { depths("encode", "h264", "H.264"), depths("encode", "h265", "H.265 (HEVC)") } },
  { title = "POOLED NATIVE H.264 ENCODER", unit = "fps", fps = true,
    src = "oicut BENCHMARKS.md · 1080p, 16 slices on 16 workers · " .. h264.machine,
    rows = { { "oicut native, QP 27", whole(h264.oicut) }, { "x264 medium, same tools", whole(h264.reference) } } },
}

return M
