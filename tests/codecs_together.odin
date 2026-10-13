// Compile gate: native codecs and both common providers coexist.
// odin check tests/codecs_together.odin -file
package main
import aacd "../codec/aac/decoder"
import aace "../codec/aac/encoder"
import h264d "../codec/h264/decoder"
import h264e "../codec/h264/encoder"
import h265d "../codec/h265/decoder"
import h265e "../codec/h265/encoder"
import media "../codec/media"
import native "../codec/media/native"
import vulkan "../codec/media/vulkan"
_ :: h264e
_ :: h264d
_ :: h265e
_ :: h265d
_ :: aace
_ :: aacd
_ :: media
_ :: native
_ :: vulkan
main :: proc() {}
