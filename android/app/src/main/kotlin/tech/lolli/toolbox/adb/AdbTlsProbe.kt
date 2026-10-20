package tech.lolli.toolbox.adb

import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.io.DataInputStream

/** Refuse a legacy plaintext endpoint when Wireless debugging was selected. */
internal object AdbTlsProbe {
    fun requireTls(host: String, port: Int) {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(host, port), 5000)
            socket.soTimeout = 5000
            val payload = "host::\u0000".toByteArray(Charsets.UTF_8)
            val connect = 0x4e584e43
            val packet = ByteBuffer.allocate(24 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(connect).putInt(0x01000001).putInt(1024 * 1024)
                .putInt(payload.size).putInt(payload.sumOf { it.toInt() and 0xff }).putInt(connect.inv()).put(payload).array()
            socket.getOutputStream().write(packet)
            socket.getOutputStream().flush()
            val header = ByteArray(24)
            DataInputStream(socket.getInputStream()).readFully(header)
            val reply = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val command = reply.int
            check(command == 0x534c5453 && reply.getInt(20) == command.inv()) {
                "This endpoint is not Wireless debugging TLS. Select legacy TCP explicitly if intended."
            }
        }
    }
}
