package tech.kirikira.kiribox.adb

import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer

/** Wire format pinned to scrcpy 5.0.1 (including its session-size packets). */
internal object ScrcpyProtocol {
    const val VERSION = "5.0.1"
    const val MAX_PACKET = 8 * 1024 * 1024
    const val H264 = 0x68323634
    data class Size(val width: Int, val height: Int, val revision: Int) {
        init { require(width in 1..65535 && height in 1..65535) }
    }
    sealed interface Packet
    data class Geometry(val width: Int, val height: Int) : Packet
    data class Frame(val data: ByteArray, val pts: Long, val config: Boolean, val key: Boolean) : Packet

    fun read(input: DataInputStream): Packet {
        val flags = input.readLong()
        val length = input.readInt()
        if (flags < 0) {
            // Session metadata is flags:u32, width:u32, height:u32, NOT a frame.
            val width = (flags and 0xffffffffL).toInt()
            if (width !in 1..65535 || length !in 1..65535) throw IOException("Invalid scrcpy video size")
            return Geometry(width, length)
        }
        if (length !in 1..MAX_PACKET) throw IOException("Invalid scrcpy packet length: $length")
        val data = ByteArray(length)
        input.readFully(data)
        return Frame(data, flags and ((1L shl 61) - 1), flags and (1L shl 62) != 0L, flags and (1L shl 61) != 0L)
    }

    fun touch(action: Int, pointer: Long, x: Double, y: Double, size: Size): ByteArray {
        require(action in 0..2 && pointer >= 0 && x.isFinite() && y.isFinite())
        return ByteBuffer.allocate(32).apply {
            put(2.toByte()); put(action.toByte()); putLong(pointer)
            putInt((x.coerceIn(0.0, 1.0) * (size.width - 1)).toInt())
            putInt((y.coerceIn(0.0, 1.0) * (size.height - 1)).toInt())
            putShort(size.width.toShort()); putShort(size.height.toShort())
            putShort((if (action == 1) 0 else 0xffff).toShort())
            putInt(0); putInt(0)
        }.array()
    }

    fun key(action: Int, key: Int): ByteArray {
        require(action in 0..1 && key in setOf(3, 4, 187))
        return ByteBuffer.allocate(14).apply {
            put(0.toByte()); put(action.toByte()); putInt(key); putInt(0); putInt(0)
        }.array()
    }

    /** Android AVC decoders require the Annex-B SPS and PPS as separate CSD. */
    fun avcConfig(data: ByteArray): Pair<ByteArray, ByteArray> {
        val starts = mutableListOf<Pair<Int, Int>>()
        var at = 0
        while (at + 3 < data.size) {
            val prefix = when {
                data[at] == 0.toByte() && data[at + 1] == 0.toByte() && data[at + 2] == 1.toByte() -> 3
                data[at] == 0.toByte() && data[at + 1] == 0.toByte() && data[at + 2] == 0.toByte() && data[at + 3] == 1.toByte() -> 4
                else -> 0
            }
            if (prefix == 0) at++ else { starts.add(at to prefix); at += prefix }
        }
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        for ((index, start) in starts.withIndex()) {
            if (start.first + start.second >= data.size) continue
            val end = starts.getOrNull(index + 1)?.first ?: data.size
            when (data[start.first + start.second].toInt() and 31) {
                7 -> sps = data.copyOfRange(start.first, end)
                8 -> pps = data.copyOfRange(start.first, end)
            }
        }
        return (sps ?: throw IOException("Missing AVC SPS")) to (pps ?: throw IOException("Missing AVC PPS"))
    }
}
