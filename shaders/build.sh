#!/usr/bin/env bash
# Compile Slang shaders to SPIR-V for Vulkan compute
set -euo pipefail
cd "$(dirname "$0")"

echo "Compiling Slang shaders -> SPIR-V..."

slangc yuv_to_rgb.slang -matrix-layout-column-major -O2 -entry cs_main -target spirv -o yuv_to_rgb.comp.spv
echo "  yuv_to_rgb.slang:cs_main -> yuv_to_rgb.comp.spv"

slangc motion_estimation.slang -matrix-layout-column-major -O2 -entry cs_main -target spirv -o motion_estimation.comp.spv
echo "  motion_estimation.slang:cs_main -> motion_estimation.comp.spv"

slangc deblock_bs.slang -matrix-layout-column-major -O2 -entry cs_main -target spirv -o deblock_bs.comp.spv
echo "  deblock_bs.slang:cs_main -> deblock_bs.comp.spv"

slangc deblock_filter.slang -matrix-layout-column-major -O2 -entry cs_main -target spirv -o deblock_filter.comp.spv
echo "  deblock_filter.slang:cs_main -> deblock_filter.comp.spv"

slangc video_readback.slang -target spirv -profile glsl_450 -entry main -stage compute -o video_readback.comp.spv
echo "  video_readback.slang:main -> video_readback.comp.spv"

slangc video_pack.slang -target spirv -profile glsl_450 -entry main -stage compute -o video_pack.comp.spv
echo "  video_pack.slang:main -> video_pack.comp.spv"

echo "Done."
