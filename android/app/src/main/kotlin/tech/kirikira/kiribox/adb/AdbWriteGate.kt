package tech.kirikira.kiribox.adb

import io.github.muntashirakon.adb.AdbStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * libadb 3.1.1 allows one WRTE in flight per stream: `write` blocks until the peer's OKAY.
 * Waiting for that OKAY *before* taking queued input lets a writer send the freshest
 * coalesced touch positions instead of ones that went stale during the round trip.
 *
 * The flag is private, so it is read reflectively (kept by proguard-rules.pro). Without it,
 * [awaitReady] returns at once and writes simply block inside libadb as before.
 * Safe only for a stream with a single writer: libadb wakes that writer with `notify()`.
 */
internal class AdbWriteGate(private val stream: AdbStream) {
    private val ready: AtomicBoolean? = runCatching {
        AdbStream::class.java.getDeclaredField("mWriteReady").apply { isAccessible = true }.get(stream) as AtomicBoolean
    }.getOrNull()

    val supported get() = ready != null

    /** True once the next write will not block, false when [timeoutMs] elapsed or the stream closed. */
    fun awaitReady(timeoutMs: Long): Boolean {
        val flag = ready ?: return true
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        synchronized(stream) {
            while (!flag.get()) {
                if (stream.isClosed) return false
                val left = (deadline - System.nanoTime()) / 1_000_000
                if (left <= 0) return false
                (stream as Object).wait(minOf(left, 50))
            }
        }
        return true
    }
}
