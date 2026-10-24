package tech.kirikira.kiribox.adb

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Handler
import io.flutter.view.TextureRegistry
import io.github.muntashirakon.adb.AdbStream
import java.io.DataInputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Video bytes never cross a Flutter channel. Only geometry/state and input do. */
internal class ScrcpySession(
    val id: String,
    val connectionId: String,
    private val manager: DeviceAdbManager,
    private val producer: TextureRegistry.SurfaceProducer,
    private val main: Handler,
    private val emit: (Map<String, Any>) -> Unit,
) {
    val closed = AtomicBoolean(false)
    private val firstFrame = AtomicBoolean(false)
    @Volatile private var video: AdbStream? = null
    @Volatile private var control: AdbStream? = null
    @Volatile private var size: ScrcpyProtocol.Size? = null
    private val frames = ArrayDeque<VideoFrame>()
    private val frameLock = Object()
    private var queuedBytes = 0
    private val inputs = ArrayDeque<Input>()
    private val inputLock = Object()
    private val pointers = mutableMapOf<Long, Touch>() // control-writer thread only
    private val workers = Executors.newCachedThreadPool()

    private data class VideoFrame(val packet: ScrcpyProtocol.Frame, val size: ScrcpyProtocol.Size, val config: ByteArray, val epoch: Int)
    private sealed interface Input
    private data class Touch(val action: Int, val pointer: Long, val x: Double, val y: Double, val revision: Int) : Input
    private data class Key(val key: Int) : Input
    private data object Release : Input
    private class Finish(val done: java.util.concurrent.CountDownLatch) : Input

    fun start() {
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceCleanup() { fail("surface", "Video surface was released") }
        })
        workers.execute { guard("video") { readVideo() } }
        workers.execute { guard("decoder") { decode() } }
        workers.execute { guard("control") { writeControl() } }
        main.postDelayed({ if (!firstFrame.get() && !closed.get()) fail("timeout", "No video frame received within 15 seconds") }, 15000)
    }

    private fun guard(stage: String, action: () -> Unit) {
        try { action() } catch (error: Exception) {
            if (!closed.get()) fail(stage, error.message ?: error.javaClass.simpleName)
        }
    }

    private fun openSocket(): AdbStream {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        var last: Exception? = null
        while (!closed.get() && System.nanoTime() < deadline) {
            try {
                val stream = manager.openStream("localabstract:scrcpy_$id")
                if (closed.get()) { stream.close(); throw IOException("Screen session cancelled") }
                return stream
            } catch (error: IOException) { last = error; Thread.sleep(100) }
        }
        throw IOException("scrcpy socket did not become available", last)
    }

    private fun readVideo() {
        val stream = openSocket()
        video = stream
        if (closed.get()) { stream.close(); return }
        val input = DataInputStream(stream.openInputStream())
        check(input.readUnsignedByte() == 0) { "Invalid scrcpy forward handshake" }
        // Accept both sockets before waiting for metadata: the server waits for control.
        control = openSocket()
        if (closed.get()) { control?.close(); return }
        synchronized(inputLock) { inputLock.notifyAll() }
        workers.execute { guard("control") {
            val source = control!!.openInputStream()
            val bytes = ByteArray(4096)
            while (!closed.get() && source.read(bytes) >= 0) { /* Clipboard/UHID are disabled. */ }
            if (!closed.get()) throw IOException("scrcpy control channel disconnected")
        } }
        input.readFully(ByteArray(64)) // device name, not a video packet
        check(input.readInt() == ScrcpyProtocol.H264) { "Unsupported scrcpy video codec" }
        var config: ByteArray? = null
        var waitingForKey = true
        var epoch = 0
        while (!closed.get()) {
            when (val packet = ScrcpyProtocol.read(input)) {
                is ScrcpyProtocol.Geometry -> {
                    check(packet.width <= 4096 && packet.height <= 4096 && packet.width.toLong() * packet.height <= 8294400L) {
                        "scrcpy video dimensions exceed decoder limits"
                    }
                    val geometry = ScrcpyProtocol.Size(packet.width, packet.height, (size?.revision ?: 0) + 1)
                    size = geometry
                    enqueue(Release)
                    config = null; waitingForKey = true; epoch++
                    synchronized(frameLock) { frames.clear(); queuedBytes = 0 }
                    event("size", mapOf("width" to geometry.width, "height" to geometry.height, "revision" to geometry.revision))
                }
                is ScrcpyProtocol.Frame -> {
                    if (packet.config) {
                        config = packet.data
                        ScrcpyProtocol.avcConfig(packet.data) // fail clearly before allocating a decoder
                        waitingForKey = true; epoch++
                        synchronized(frameLock) { frames.clear(); queuedBytes = 0 }
                        continue
                    }
                    val geometry = size ?: throw IOException("Video arrived before session metadata")
                    val csd = config ?: throw IOException("Video arrived before AVC configuration")
                    synchronized(frameLock) {
                        if (frames.size >= 4 || queuedBytes + packet.data.size > ScrcpyProtocol.MAX_PACKET) {
                            frames.clear(); queuedBytes = 0; waitingForKey = true; epoch++
                        }
                        if (!waitingForKey || packet.key) {
                            waitingForKey = false
                            frames.addLast(VideoFrame(packet, geometry, csd, epoch))
                            queuedBytes += packet.data.size
                            frameLock.notifyAll()
                        }
                    }
                }
            }
        }
    }

    private fun <T> onMain(action: () -> T): T {
        val task = FutureTask(action)
        main.post(task)
        return task.get(3, TimeUnit.SECONDS)
    }

    private fun decode() {
        var codec: MediaCodec? = null
        var epoch = -1
        val info = MediaCodec.BufferInfo()
        fun drain(decoder: MediaCodec) {
            while (!closed.get()) {
                val index = decoder.dequeueOutputBuffer(info, 0)
                if (index >= 0) {
                    decoder.releaseOutputBuffer(index, true)
                    // Some codecs delay OnFrameRendered until the consumer presents.
                    // Output already submitted to the Surface is sufficient to show it.
                    if (firstFrame.compareAndSet(false, true)) event("streaming")
                }
                else if (index != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED && index != MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED) break
            }
        }
        try {
            while (!closed.get()) {
                val frame = synchronized(frameLock) {
                    if (frames.isEmpty() && !closed.get()) frameLock.wait(20)
                    frames.pollFirst()?.also { queuedBytes -= it.packet.data.size }
                }
                if (frame == null) { codec?.let { drain(it) }; continue }
                if (frame.size.revision != size?.revision) continue
                if (frame.epoch != epoch) {
                    codec?.let { runCatching { it.stop() }; it.release() }; codec = null
                    val surface = onMain {
                        check(!closed.get())
                        producer.setSize(frame.size.width, frame.size.height)
                        producer.surface
                    }
                    val csd = ScrcpyProtocol.avcConfig(frame.config)
                    val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, frame.size.width, frame.size.height).apply {
                        setByteBuffer("csd-0", ByteBuffer.wrap(csd.first))
                        setByteBuffer("csd-1", ByteBuffer.wrap(csd.second))
                        setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, ScrcpyProtocol.MAX_PACKET)
                    }
                    val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                    codec = decoder
                    decoder.configure(format, surface, null, 0)
                    decoder.setOnFrameRenderedListener({ _, _, _ ->
                        if (!closed.get() && firstFrame.compareAndSet(false, true)) event("streaming")
                    }, main)
                    decoder.start(); epoch = frame.epoch
                }
                val decoder = codec ?: continue
                var index = -1
                while (!closed.get() && index < 0) {
                    drain(decoder)
                    index = decoder.dequeueInputBuffer(10000)
                }
                if (closed.get()) break
                val buffer = decoder.getInputBuffer(index) ?: throw IOException("Decoder input unavailable")
                check(buffer.capacity() >= frame.packet.data.size) { "AVC frame exceeds decoder buffer" }
                buffer.clear(); buffer.put(frame.packet.data)
                decoder.queueInputBuffer(index, 0, frame.packet.data.size, frame.packet.pts, 0)
                drain(decoder)
            }
        } finally {
            codec?.let { runCatching { it.stop() }; runCatching { it.release() } }
            main.post { producer.release() }
        }
    }

    fun touch(action: Int, pointer: Long, x: Double, y: Double, revision: Int) {
        require(action in 0..2 && pointer >= 0 && x.isFinite() && y.isFinite())
        if (!closed.get()) enqueue(Touch(action, pointer, x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0), revision))
    }
    fun key(key: Int) { require(key in setOf(3, 4, 187)); if (!closed.get()) enqueue(Key(key)) }
    fun releasePointers() { if (!closed.get()) enqueue(Release) }

    private fun enqueue(value: Input) {
        synchronized(inputLock) {
            if (value is Touch && value.action == 2) {
                // Coalesce only within the same pointer lifetime (never across DOWN/UP).
                val iterator = inputs.descendingIterator()
                while (iterator.hasNext()) {
                    val previous = iterator.next()
                    if (previous is Touch && previous.pointer == value.pointer) {
                        if (previous.action == 2 && previous.revision == value.revision) iterator.remove()
                        break
                    }
                    if (previous is Release || previous is Finish) break
                }
            }
            if (inputs.size >= 256) inputs.removeAll { it is Touch && it.action == 2 }
            if (inputs.size >= 256) throw IOException("scrcpy input queue is full")
            inputs.addLast(value); inputLock.notifyAll()
        }
    }

    private fun writeControl() {
        while (!closed.get() && control == null) synchronized(inputLock) { inputLock.wait(100) }
        val output = control?.openOutputStream() ?: return
        fun release() {
            val geometry = size
            if (geometry != null) for (pointer in pointers.values) {
                output.write(ScrcpyProtocol.touch(1, pointer.pointer, pointer.x, pointer.y, geometry))
            }
            pointers.clear(); output.flush()
        }
        while (true) {
            val input = synchronized(inputLock) {
                // Finish must still release held fingers after closed becomes true.
                while (inputs.isEmpty()) inputLock.wait(100)
                inputs.pollFirst()
            } ?: break
            when (input) {
                is Touch -> {
                    val geometry = size ?: continue
                    if (closed.get() || input.revision != geometry.revision) continue
                    if (input.action == 0) {
                        if (pointers.containsKey(input.pointer) || pointers.size >= 10) continue
                        pointers[input.pointer] = input
                    } else {
                        if (!pointers.containsKey(input.pointer)) continue
                        if (input.action == 1) pointers.remove(input.pointer) else pointers[input.pointer] = input
                    }
                    output.write(ScrcpyProtocol.touch(input.action, input.pointer, input.x, input.y, geometry)); output.flush()
                }
                is Key -> if (!closed.get()) {
                    output.write(ScrcpyProtocol.key(0, input.key)); output.write(ScrcpyProtocol.key(1, input.key)); output.flush()
                }
                Release -> release()
                is Finish -> { try { release() } finally { input.done.countDown() }; return }
            }
        }
    }

    private fun event(state: String, details: Map<String, Any> = emptyMap()) {
        main.post { emit(mapOf("session" to id, "state" to state) + details) }
    }
    private fun fail(stage: String, message: String) {
        if (!closed.get()) {
            event("error", mapOf("stage" to stage, "message" to message))
            stop()
        }
    }
    fun stop(onStopped: (() -> Unit)? = null) {
        if (!closed.compareAndSet(false, true)) { onStopped?.invoke(); return }
        workers.execute {
            // Best effort UP before closing; a broken network must not block teardown.
            val latch = java.util.concurrent.CountDownLatch(1)
            runCatching { enqueue(Finish(latch)); latch.await(250, TimeUnit.MILLISECONDS) }
            runCatching { control?.close() }; runCatching { video?.close() }
            synchronized(frameLock) { frames.clear(); queuedBytes = 0; frameLock.notifyAll() }
            synchronized(inputLock) { inputs.clear(); inputLock.notifyAll() }
            workers.shutdownNow()
            if (onStopped != null) main.post(onStopped)
        }
    }
}
