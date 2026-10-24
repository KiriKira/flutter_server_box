package tech.kirikira.kiribox.adb

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors

internal class ScrcpyBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
    private val connection: (String) -> DeviceAdbManager?,
) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newSingleThreadExecutor()
    private val channel = EventChannel(messenger, "tech.kirikira.kiribox/scrcpy/events")
    private var sink: EventChannel.EventSink? = null
    private var current: ScrcpySession? = null
    init { channel.setStreamHandler(this) }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null; current?.stop(); current = null }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "screenAsset" -> workers.execute {
                    try {
                        val bytes = context.assets.open("kiribox-scrcpy-server.jar").use { it.readBytes() }
                        check(bytes.size in 1..(2 * 1024 * 1024)) { "Invalid bundled scrcpy server" }
                        main.post { result.success(mapOf("version" to ScrcpyProtocol.VERSION, "bytes" to bytes)) }
                    } catch (error: Exception) { main.post { result.error("scrcpy", error.message, null) } }
                }
                "screenStart" -> {
                    val id = call.argument<String>("session") ?: error("Missing session")
                    check(id.matches(Regex("[0-7][0-9a-f]{7}")) && id != "00000000") { "Invalid scrcpy session" }
                    val connectionId = call.argument<String>("id") ?: error("Missing ADB connection")
                    val manager = connection(connectionId) ?: error("ADB disconnected")
                    current?.stop()
                    val producer = textures.createSurfaceProducer()
                    val session = ScrcpySession(id, connectionId, manager, producer, main) { event ->
                        if (current?.id == id) sink?.success(event)
                    }
                    current = session
                    session.start()
                    result.success(mapOf("texture" to producer.id()))
                }
                "screenStop" -> {
                    val session = current.takeIf { it?.id == call.argument<String>("session") }
                    if (session == null) result.success(null) else {
                        current = null
                        session.stop { result.success(null) }
                    }
                }
                "screenTouch" -> {
                    val session = requiredSession(call)
                    session.touch(call.argument<Int>("action")!!, call.argument<Number>("pointer")!!.toLong(),
                        call.argument<Number>("x")!!.toDouble(), call.argument<Number>("y")!!.toDouble(), call.argument<Int>("revision")!!)
                    result.success(null)
                }
                "screenKey" -> { requiredSession(call).key(call.argument<Int>("key")!!); result.success(null) }
                "screenRelease" -> { requiredSession(call).releasePointers(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { result.error("scrcpy", error.message ?: "Screen session failed", null) }
    }

    private fun requiredSession(call: MethodCall): ScrcpySession =
        current?.takeIf { it.id == call.argument<String>("session") && !it.closed.get() } ?: error("Screen session is closed")

    fun disconnect(id: String) {
        main.post { if (current?.connectionId == id) { current?.stop(); current = null } }
    }
    fun close() {
        current?.stop(); current = null; sink = null
        channel.setStreamHandler(null); workers.shutdownNow()
    }
}
