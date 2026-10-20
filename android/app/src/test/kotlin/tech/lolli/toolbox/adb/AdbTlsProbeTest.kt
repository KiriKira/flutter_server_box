package tech.lolli.toolbox.adb

import org.junit.Assert.assertThrows
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.ServerSocket
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

class AdbTlsProbeTest {
    private fun withPeer(command: Int, test: (Int) -> Unit) {
        ServerSocket(0).use { server ->
            val peer = thread(isDaemon = true) {
                server.accept().use { socket ->
                    socket.soTimeout = 5000
                    val header = ByteArray(24)
                    val input = DataInputStream(socket.getInputStream())
                    input.readFully(header)
                    val size = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getInt(12)
                    val payload = ByteArray(size)
                    input.readFully(payload)
                    assertEquals(payload.sumOf { it.toInt() and 0xff }, ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getInt(16))
                    socket.getOutputStream().write(ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
                        .putInt(command).putInt(0).putInt(0).putInt(0).putInt(0).putInt(command.inv()).array())
                }
            }
            test(server.localPort)
            peer.join(5000)
        }
    }
    @Test fun acceptsWirelessTlsHandshake() = withPeer(0x534c5453) { port -> AdbTlsProbe.requireTls("127.0.0.1", port) }
    @Test fun refusesLegacyPlaintextHandshake() = withPeer(0x4e584e43) { port ->
        assertThrows(IllegalStateException::class.java) { AdbTlsProbe.requireTls("127.0.0.1", port) }
    }
}
