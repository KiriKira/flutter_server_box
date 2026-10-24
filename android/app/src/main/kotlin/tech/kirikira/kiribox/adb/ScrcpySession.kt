package tech.kirikira.kiribox.adb

import android.content.ClipboardManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import io.flutter.view.TextureRegistry
import io.github.muntashirakon.adb.AdbStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Video bytes never cross a Flutter channel. Only geometry/state and input do. */
internal class ScrcpySession(
    val id: String,
    val connectionId: String,
    private val manager: DeviceAdbManager,
    private val producer: TextureRegistry.SurfaceProducer,
    private val main: Handler,
    private val clipboard: ScrcpyClipboard,
    private val emit: (Map<String, Any>) -> Unit,
) {
    val closed = AtomicBoolean(false)
    private val firstFrame = AtomicBoolean(false)
    @Volatile private var video: AdbStream? = null
    @Volatile private var control: AdbStream? = null
    @Volatile private var size: ScrcpyProtocol.Size? = null
    @Volatile private var activeCodec: MediaCodec? = null
    private val frames = ArrayDeque<VideoFrame>()
    private val frameLock = Object()
    private var queuedBytes = 0
    private val inputs = ArrayDeque<Input>()
    private val inputLock = Object()
    private val pointers = mutableMapOf<Long, Touch>() // control-writer thread only
    private val workers = Executors.newCachedThreadPool()
    private val callbacks = HandlerThread("scrcpy-decoder-$id").also { it.start() }
    private val hostClipboard = ClipboardManager.OnPrimaryClipChangedListener { pushHostClipboard() }
    // Link health, read by the stats tick on the main thread.
    @Volatile private var awaitingAckSince = 0L // nanoTime; 0 when adbd acknowledged every control write
    @Volatile private var rttMs = -1L
    @Volatile private var lagMs = 0L
    private val videoBytes = AtomicLong()
    private val renderedFrames = AtomicLong()
    private var lastRenderAt = 0L // decoder callback thread only
    @Volatile private var decoderName = ""
    private var resetRequestedAt = 0L // video thread only

    private data class VideoFrame(val packet: ScrcpyProtocol.Frame, val size: ScrcpyProtocol.Size, val config: ByteArray, val epoch: Int)
    private sealed interface Input
    private data class Touch(val action: Int, val pointer: Long, val x: Double, val y: Double, val revision: Int) : Input
    private data class Key(val key: Int) : Input
    private class Clipboard(val text: String) : Input
    private data object Release : Input
    private data object ResetVideo : Input
    private class Finish(val done: java.util.concurrent.CountDownLatch) : Input

    private companion object {
        const val MAX_QUEUED_FRAMES = 120
        const val MAX_QUEUED_BYTES = 16 * 1024 * 1024
        const val PING_INTERVAL_NS = 2_000_000_000L
        const val DEAD_LINK_MS = 15_000L
    }

    /** One configured codec; input indices arrive from its callback thread. */
    private class Decoder(val codec: MediaCodec, val epoch: Int) {
        val inputs = LinkedBlockingQueue<Int>()
    }

    fun start() {
        clipboard.addListener(hostClipboard)
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            override fun onSurfaceCleanup() { fail("surface", "Video surface was released") }
        })
        workers.execute { guard("video") { readVideo() } }
        workers.execute { guard("decoder") { decode() } }
        workers.execute { guard("control") { writeControl() } }
        main.postDelayed({ if (!firstFrame.get() && !closed.get()) fail("timeout", "No video frame received within 25 seconds") }, 25000)
        main.postDelayed(::tick, 1000)
    }

    private var tickBytes = 0L
    private var tickFrames = 0L
    private var tickAt = System.nanoTime()

    /** Once a second: link statistics for the viewer, and the dead-link verdict. */
    private fun tick() {
        if (closed.get()) return
        val now = System.nanoTime()
        val since = awaitingAckSince
        val pendingMs = if (since == 0L) 0L else (now - since) / 1_000_000
        if (firstFrame.get() && pendingMs > DEAD_LINK_MS) {
            fail("network", "No ADB acknowledgement for ${pendingMs / 1000} s; the connection to the target was lost")
            return
        }
        val seconds = ((now - tickAt) / 1e9).coerceAtLeast(0.001)
        val bytes = videoBytes.get(); val rendered = renderedFrames.get()
        event("stats", mapOf(
            "rtt" to rttMs, "lag" to lagMs, "pending" to pendingMs, "decoder" to decoderName,
            "kbps" to ((bytes - tickBytes) * 8 / 1000 / seconds).toLong(),
            "fps" to ((rendered - tickFrames) / seconds).toLong(),
        ))
        tickBytes = bytes; tickFrames = rendered; tickAt = now
        main.postDelayed(::tick, 1000)
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
        // The target has not seen a host clip copied before this session (or while backgrounded).
        main.post { pushHostClipboard() }
        workers.execute { guard("control") {
            val source = DataInputStream(control!!.openInputStream())
            try {
                while (!closed.get()) {
                    val message = ScrcpyProtocol.readDeviceMessage(source)
                    if (message is ScrcpyProtocol.Clipboard) main.post { if (!closed.get()) clipboard.fromDevice(message.text) }
                }
            } catch (end: EOFException) {
                if (!closed.get()) throw IOException("scrcpy control channel disconnected")
            }
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
                    videoBytes.addAndGet(packet.data.size.toLong())
                    measureLag(packet.pts)
                    synchronized(frameLock) {
                        // A burst after a stall is decoded in full and only its newest frame shown.
                        // Dropping is the last resort: a key frame is requested rather than awaited,
                        // since the encoder sends one on its own only every 10 seconds.
                        if (frames.size >= MAX_QUEUED_FRAMES || queuedBytes + packet.data.size > MAX_QUEUED_BYTES) {
                            frames.clear(); queuedBytes = 0; waitingForKey = true; epoch++
                            requestKeyFrame()
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

    private var offsetMin = Long.MAX_VALUE
    private var offsetPreviousMin = Long.MAX_VALUE
    private var offsetBucketAt = 0L

    /**
     * Queuing delay of the newest frame: its arrival-minus-capture offset above the fastest one
     * seen in the last 30-60 s. The clocks' fixed difference and the base round trip cancel out;
     * the sliding window absorbs drift between the two phones' clocks.
     */
    private fun measureLag(pts: Long) {
        val now = System.nanoTime() / 1000
        val offset = now - pts
        if (now - offsetBucketAt > 30_000_000) { offsetPreviousMin = offsetMin; offsetMin = Long.MAX_VALUE; offsetBucketAt = now }
        if (offset < offsetMin) offsetMin = offset
        lagMs = (offset - minOf(offsetMin, offsetPreviousMin)) / 1000
    }

    private fun requestKeyFrame() {
        val now = System.nanoTime()
        if (now - resetRequestedAt < 1_000_000_000L) return
        resetRequestedAt = now
        runCatching { enqueue(ResetVideo) }
    }

    private fun <T> onMain(action: () -> T): T {
        val task = FutureTask(action)
        main.post(task)
        return task.get(3, TimeUnit.SECONDS)
    }

    private fun decode() {
        var decoder: Decoder? = null
        fun discard() {
            activeCodec = null
            decoder?.codec?.let { runCatching { it.stop() }; runCatching { it.release() } }; decoder = null
        }
        try {
            while (!closed.get()) {
                val frame = synchronized(frameLock) {
                    if (frames.isEmpty() && !closed.get()) frameLock.wait(20)
                    frames.pollFirst()?.also { queuedBytes -= it.packet.data.size }
                }
                if (frame == null || frame.size.revision != size?.revision) continue
                if (frame.epoch != decoder?.epoch) {
                    discard()
                    val surface = onMain {
                        check(!closed.get())
                        producer.setSize(frame.size.width, frame.size.height)
                        producer.surface
                    }
                    decoder = createDecoder(frame, surface)
                }
                val current = decoder ?: continue
                var index: Int? = null
                while (!closed.get() && index == null) index = current.inputs.poll(10, TimeUnit.MILLISECONDS)
                if (closed.get() || index == null) break
                val buffer = current.codec.getInputBuffer(index) ?: throw IOException("Decoder input unavailable")
                check(buffer.capacity() >= frame.packet.data.size) { "AVC frame exceeds decoder buffer" }
                buffer.clear(); buffer.put(frame.packet.data)
                current.codec.queueInputBuffer(index, 0, frame.packet.data.size, frame.packet.pts, 0)
            }
        } finally {
            discard()
            callbacks.quitSafely()
            main.post { producer.release() }
        }
    }

    /**
     * Asynchronous mode renders each output buffer the moment it is ready, rather than at the next
     * input or poll. Low-latency decoding stops decoders that otherwise hold several frames back;
     * a decoder that refuses those keys is configured again without them.
     */
    private fun createDecoder(frame: VideoFrame, surface: Surface): Decoder {
        val csd = ScrcpyProtocol.avcConfig(frame.config)
        var failure: Exception? = null
        for (lowLatency in listOf(true, false)) {
            val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            val decoder = Decoder(codec, frame.epoch)
            try {
                codec.setCallback(object : MediaCodec.Callback() {
                    override fun onInputBufferAvailable(source: MediaCodec, index: Int) { decoder.inputs.offer(index) }
                    override fun onOutputBufferAvailable(source: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                        // Catching up after a stall: skip frames a newer queued one replaces, but
                        // still show one every 100 ms so the picture visibly moves.
                        val now = System.nanoTime()
                        val behind = synchronized(frameLock) { frames.isNotEmpty() }
                        val render = !behind || now - lastRenderAt > 100_000_000L
                        // A codec being stopped by the decode thread refuses the release; nothing to show then.
                        if (!runCatching { source.releaseOutputBuffer(index, render) }.isSuccess || !render) return
                        lastRenderAt = now
                        renderedFrames.incrementAndGet()
                        if (!closed.get() && firstFrame.compareAndSet(false, true)) event("streaming")
                    }
                    override fun onError(source: MediaCodec, error: MediaCodec.CodecException) {
                        // A codec already replaced (rotation, new configuration) is not this session failing.
                        if (source === activeCodec) fail("decoder", error.diagnosticInfo ?: error.message ?: "Decoder error")
                    }
                    override fun onOutputFormatChanged(source: MediaCodec, format: MediaFormat) {}
                }, Handler(callbacks.looper))
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, frame.size.width, frame.size.height).apply {
                    setByteBuffer("csd-0", ByteBuffer.wrap(csd.first))
                    setByteBuffer("csd-1", ByteBuffer.wrap(csd.second))
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, ScrcpyProtocol.MAX_PACKET)
                    if (lowLatency) {
                        setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
                        if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                        // Qualcomm decoders predating KEY_LOW_LATENCY still reorder frames without this.
                        if (codec.name.startsWith("OMX.qcom.") || codec.name.startsWith("c2.qti.")) {
                            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                        }
                    }
                }
                codec.configure(format, surface, null, 0)
                codec.setOnFrameRenderedListener({ _, _, _ ->
                    if (!closed.get() && firstFrame.compareAndSet(false, true)) event("streaming")
                }, main)
                codec.start()
                activeCodec = codec
                decoderName = codec.name + if (lowLatency) " (low latency)" else ""
                return decoder
            } catch (error: Exception) {
                runCatching { codec.release() }
                if (error is InterruptedException || closed.get()) throw error
                failure = error
            }
        }
        throw failure ?: IOException("No AVC decoder")
    }

    fun touch(action: Int, pointer: Long, x: Double, y: Double, revision: Int) {
        require(action in 0..2 && pointer >= 0 && x.isFinite() && y.isFinite())
        if (!closed.get()) enqueue(Touch(action, pointer, x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0), revision))
    }
    fun key(key: Int) { require(key in setOf(3, 4, 187)); if (!closed.get()) enqueue(Key(key)) }
    fun releasePointers() { if (!closed.get()) enqueue(Release) }

    private fun pushHostClipboard() {
        if (closed.get() || control == null) return
        val text = clipboard.takeHostChange() ?: return
        runCatching { enqueue(Clipboard(text)) }
    }

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

    /**
     * One control write is in flight at a time (libadb waits for adbd's OKAY), so over a slow link
     * each write costs a round trip. Everything queued meanwhile goes out together in the next
     * write, after that OKAY, with moves already coalesced to each finger's latest position.
     */
    private fun writeControl() {
        while (!closed.get() && control == null) synchronized(inputLock) { inputLock.wait(100) }
        val stream = control ?: return
        val output = stream.openOutputStream()
        val gate = AdbWriteGate(stream)
        val batch = ByteArrayOutputStream()
        var lastSendAt = System.nanoTime()
        fun awaitAck() {
            val since = awaitingAckSince
            if (!gate.supported || since == 0L) return
            while (!gate.awaitReady(1000)) if (stream.isClosed) return // the write fails and ends the session
            val sample = (System.nanoTime() - since) / 1_000_000
            rttMs = if (rttMs < 0) sample else (rttMs * 7 + sample) / 8
            awaitingAckSince = 0L
        }
        fun send() {
            if (batch.size() == 0) return
            awaitAck()
            lastSendAt = System.nanoTime()
            if (!gate.supported) awaitingAckSince = lastSendAt // libadb blocks inside write instead
            output.write(batch.toByteArray()); output.flush(); batch.reset()
            awaitingAckSince = if (gate.supported) System.nanoTime() else 0L
        }
        fun release() {
            val geometry = size
            if (geometry != null) for (pointer in pointers.values) {
                batch.write(ScrcpyProtocol.touch(1, pointer.pointer, pointer.x, pointer.y, geometry))
            }
            pointers.clear()
        }
        while (true) {
            awaitAck()
            val drained = synchronized(inputLock) {
                // Finish must still release held fingers after closed becomes true.
                while (inputs.isEmpty() && (closed.get() || System.nanoTime() - lastSendAt < PING_INTERVAL_NS)) inputLock.wait(100)
                ArrayList(inputs).also { inputs.clear() }
            }
            if (drained.isEmpty()) batch.write(ScrcpyProtocol.ping())
            for (input in drained) when (input) {
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
                    batch.write(ScrcpyProtocol.touch(input.action, input.pointer, input.x, input.y, geometry))
                }
                is Key -> if (!closed.get()) { batch.write(ScrcpyProtocol.key(0, input.key)); batch.write(ScrcpyProtocol.key(1, input.key)) }
                // Up to 256 KiB: alone in its write, so no write exceeds adbd's smallest payload limit.
                is Clipboard -> if (!closed.get()) { send(); batch.write(ScrcpyProtocol.setClipboard(input.text)); send() }
                ResetVideo -> if (!closed.get()) batch.write(ScrcpyProtocol.resetVideo())
                Release -> release()
                is Finish -> { try { release(); send() } finally { input.done.countDown() }; return }
            }
            send()
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
        main.post { clipboard.removeListener(hostClipboard) }
        workers.execute {
            // Best effort UP before closing; a broken network must not block teardown.
            val latch = java.util.concurrent.CountDownLatch(1)
            runCatching { enqueue(Finish(latch)); latch.await(250, TimeUnit.MILLISECONDS) }
            runCatching { control?.close() }; runCatching { video?.close() }
            synchronized(frameLock) { frames.clear(); queuedBytes = 0; frameLock.notifyAll() }
            synchronized(inputLock) { inputs.clear(); inputLock.notifyAll() }
            workers.shutdownNow()
            callbacks.quitSafely()
            if (onStopped != null) main.post(onStopped)
        }
    }
}
