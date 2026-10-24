package tech.kirikira.kiribox.adb

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer

class ScrcpyProtocolTest {
    private fun input(bytes: ByteArray) = DataInputStream(object : InputStream() {
        val source = ByteArrayInputStream(bytes)
        override fun read() = source.read()
        override fun read(buffer: ByteArray, offset: Int, count: Int) = source.read(buffer, offset, minOf(1, count))
    })
    private fun hex(value: String) = value.filterNot { it.isWhitespace() }.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun sessionMetadataIsNotAFrameLength() {
        val data = ByteBuffer.allocate(24).putInt(0x80000000.toInt()).putInt(1080).putInt(1920)
            .putInt(0x80000001.toInt()).putInt(1920).putInt(1080).array()
        val stream = input(data)
        assertEquals(ScrcpyProtocol.Geometry(1080, 1920), ScrcpyProtocol.read(stream))
        assertEquals(ScrcpyProtocol.Geometry(1920, 1080), ScrcpyProtocol.read(stream))
    }
    @Test fun packetFlagsAndTimestampsSurviveFragmentedReads() {
        val config = byteArrayOf(0, 0, 0, 1, 103, 1)
        val bytes = ByteBuffer.allocate(12 + config.size + 14)
            .putLong(1L shl 62).putInt(config.size).put(config)
            .putLong((1L shl 61) or 123456L).putInt(2).put(1.toByte()).put(2.toByte()).array()
        val stream = input(bytes)
        val first = ScrcpyProtocol.read(stream) as ScrcpyProtocol.Frame
        assertTrue(first.config); assertFalse(first.key); assertArrayEquals(config, first.data)
        val second = ScrcpyProtocol.read(stream) as ScrcpyProtocol.Frame
        assertFalse(second.config); assertTrue(second.key); assertEquals(123456L, second.pts)
        assertArrayEquals(byteArrayOf(1, 2), second.data)
    }
    @Test fun refusesOversizedAndTruncatedPackets() {
        for (length in listOf(-1, 0, ScrcpyProtocol.MAX_PACKET + 1)) {
            assertThrows(IOException::class.java) { ScrcpyProtocol.read(input(ByteBuffer.allocate(12).putLong(0).putInt(length).array())) }
        }
        assertThrows(EOFException::class.java) { ScrcpyProtocol.read(input(ByteBuffer.allocate(13).putLong(0).putInt(2).put(1.toByte()).array())) }
    }
    @Test fun touchUsesUpstreamBigEndian32ByteLayout() {
        val size = ScrcpyProtocol.Size(1080, 1920, 1)
        assertArrayEquals(hex("02 00 0000000000000007 0000021b 000003bf 0438 0780 ffff 00000000 00000000"),
            ScrcpyProtocol.touch(0, 7, 0.5, 0.5, size))
        val up = ScrcpyProtocol.touch(1, 8, 1.5, -1.0, size)
        val reader = ByteBuffer.wrap(up)
        assertEquals(2, reader.get().toInt()); assertEquals(1, reader.get().toInt())
        assertEquals(8L, reader.long); assertEquals(1079, reader.int); assertEquals(0, reader.int)
        assertEquals(1080, reader.short.toInt()); assertEquals(1920, reader.short.toInt()); assertEquals(0, reader.short.toInt())
    }
    @Test fun keyUsesUpstream14ByteLayoutAndDoesNotEnableAnHidKeyboard() {
        assertArrayEquals(hex("00 00 00000004 00000000 00000000"), ScrcpyProtocol.key(0, 4))
        assertArrayEquals(hex("00 01 00000003 00000000 00000000"), ScrcpyProtocol.key(1, 3))
        assertThrows(IllegalArgumentException::class.java) { ScrcpyProtocol.key(0, 26) }
    }
    @Test fun setClipboardUsesUpstreamLayoutWithoutAckOrPaste() {
        assertArrayEquals(hex("09 0000000000000000 00 00000003 e4bda0"), ScrcpyProtocol.setClipboard("\u4f60"))
        val big = ScrcpyProtocol.setClipboard("\u4f60".repeat(ScrcpyProtocol.CLIPBOARD_TO_DEVICE_MAX))
        val length = ByteBuffer.wrap(big, 10, 4).int
        // The 3-byte character that would cross the limit is dropped whole.
        assertEquals(ScrcpyProtocol.CLIPBOARD_TO_DEVICE_MAX / 3 * 3, length)
        assertEquals(14 + length, big.size)
    }
    @Test fun resetAndPingAreUpstreamControlMessagesWithoutSideEffects() {
        assertArrayEquals(byteArrayOf(17), ScrcpyProtocol.resetVideo()) // TYPE_RESET_VIDEO, no payload
        assertArrayEquals(byteArrayOf(8, 0), ScrcpyProtocol.ping()) // TYPE_GET_CLIPBOARD, COPY_KEY_NONE
    }
    @Test fun utf8PrefixNeverSplitsACodePoint() {
        assertArrayEquals("a".toByteArray(), ScrcpyProtocol.utf8Prefix("a\u00e9", 2))
        assertArrayEquals("a\u00e9".toByteArray(), ScrcpyProtocol.utf8Prefix("a\u00e9", 3))
        assertArrayEquals(ByteArray(0), ScrcpyProtocol.utf8Prefix("\ud83d\ude00", 3))
    }
    @Test fun readsDeviceMessagesFromFragmentedStream() {
        val text = "\u526a\u8d34\u677f".toByteArray()
        val bytes = ByteBuffer.allocate(5 + text.size + 9 + 7)
            .put(0.toByte()).putInt(text.size).put(text)
            .put(1.toByte()).putLong(42)
            .put(2.toByte()).putShort(7).putShort(2).put(1.toByte()).put(2.toByte()).array()
        val stream = input(bytes)
        assertEquals(ScrcpyProtocol.Clipboard("\u526a\u8d34\u677f"), ScrcpyProtocol.readDeviceMessage(stream))
        assertEquals(ScrcpyProtocol.ClipboardAck(42), ScrcpyProtocol.readDeviceMessage(stream))
        val uhid = ScrcpyProtocol.readDeviceMessage(stream) as ScrcpyProtocol.Uhid
        assertEquals(7, uhid.id); assertArrayEquals(byteArrayOf(1, 2), uhid.data)
        assertThrows(EOFException::class.java) { ScrcpyProtocol.readDeviceMessage(stream) }
    }
    @Test fun refusesUnknownOrOversizedDeviceMessages() {
        assertThrows(IOException::class.java) { ScrcpyProtocol.readDeviceMessage(input(byteArrayOf(9))) }
        assertThrows(IOException::class.java) {
            ScrcpyProtocol.readDeviceMessage(input(ByteBuffer.allocate(5).put(0.toByte()).putInt(ScrcpyProtocol.CLIPBOARD_FROM_DEVICE_MAX + 1).array()))
        }
    }
    @Test fun splitsMixedAnnexBStartCodesIntoSpsAndPps() {
        val data = hex("00000001674201 00000168aabb")
        val (sps, pps) = ScrcpyProtocol.avcConfig(data)
        assertArrayEquals(hex("00000001674201"), sps)
        assertArrayEquals(hex("00000168aabb"), pps)
        assertThrows(IOException::class.java) { ScrcpyProtocol.avcConfig(sps) }
    }
}
