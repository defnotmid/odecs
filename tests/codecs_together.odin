// Compile gate: native codecs and both common providers coexist.
// odin check tests/codecs_together.odin -file
package main
import aacd "../aac/decoder"
import aace "../aac/encoder"
import h264d "../h264/decoder"
import h264e "../h264/encoder"
import h265d "../h265/decoder"
import h265e "../h265/encoder"
import media "../media"
import native "../media/native"
import vulkan "../media/vulkan"
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
