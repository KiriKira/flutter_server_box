package tech.lolli.toolbox.adb

import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.muntashirakon.adb.AdbStream
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Native owns authenticated ADB connections; Dart owns service protocols. */
class AdbBridge(private val context: Context, messenger: BinaryMessenger, private val requestNotifications: () -> Boolean = { true }) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()
    private val connections = ConcurrentHashMap<String, DeviceAdbManager>()
    private val streams = ConcurrentHashMap<String, Pair<String, AdbStream>>()
    private val sequence = AtomicLong()

    init { MethodChannel(messenger, "tech.lolli.toolbox/adb").setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "discover") {
            discover(context, call.argument<Boolean>("local") == true, call.argument<Boolean>("pairing") == true) {
                result.success(it)
            }
            return
        }
        if (call.method == "settings") {
            try {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: android.content.ActivityNotFoundException) {
                context.startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            result.success(null)
            return
        }
        if (call.method == "startLocalPairing") {
            if (!requestNotifications()) { result.error("adb", "Allow notifications, then retry local pairing or use manual pairing", null); return }
            if (Build.VERSION.SDK_INT < 30) { result.error("adb", "Wireless debugging requires Android 11+", null); return }
            val intent = Intent(context, AdbPairingService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            result.success(null)
            return
        }
        if (call.method == "pairingState") { result.success(AdbPairingService.state); return }
        if (call.method == "stopPairing") {
            context.stopService(Intent(context, AdbPairingService::class.java)); result.success(null); return
        }
        workers.execute {
            try {
                val answer: Any? = when (call.method) {
                    "apkInfo" -> {
                        val path = required(call, "path")
                        @Suppress("DEPRECATION")
                        val info = context.packageManager.getPackageArchiveInfo(path, 0) ?: error("Invalid APK archive")
                        @Suppress("DEPRECATION")
                        val version = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
                        mapOf("package" to info.packageName, "version" to version.toString())
                    }
                    "pair" -> {
                        val manager = DeviceAdbManager(context)
                        try {
                            check(manager.pair(required(call, "host"), call.argument<Int>("port")!!, required(call, "code"))) { "ADB pairing rejected" }
                        } finally { manager.close() }
                        null
                    }
                    "connect" -> {
                        val id = required(call, "id")
                        val manager = DeviceAdbManager(context)
                        val local = call.argument<Boolean>("localDevice") == true
                        val tls = call.argument<Boolean>("tls") != false
                        val configuredHost = required(call, "host")
                        var host = configuredHost
                        var port = call.argument<Int>("port") ?: 0
                        val guid = call.argument<String>("deviceGuid")
                        if (tls && (local || !guid.isNullOrBlank() || port == 0)) {
                            val latch = CountDownLatch(1)
                            var candidates: List<Map<String, Any>> = emptyList()
                            main.post { discover(context, local, false) { candidates = it; latch.countDown() } }
                            check(latch.await(8, TimeUnit.SECONDS)) { "ADB discovery timed out" }
                            val found = candidates.firstOrNull {
                                if (local) true else if (!guid.isNullOrBlank()) (it["name"] as String).startsWith("adb-$guid")
                                else it["host"] == configuredHost
                            }
                            if (found != null) { host = found["host"] as String; port = found["port"] as Int }
                            else if (local || port == 0) error("Enable Wireless debugging; no matching ADB service found")
                        }
                        check(port in 1..65535) { "Invalid ADB connection port" }
                        try {
                            if (tls) AdbTlsProbe.requireTls(host, port)
                            manager.setThrowOnUnauthorised(tls)
                            manager.setTimeout(if (tls) 12 else 60, TimeUnit.SECONDS)
                            manager.setHostAddress(host)
                            check(manager.connect(host, port) || manager.isConnected) { "ADB connect failed" }
                            connections.put(id, manager)?.close()
                        } catch (e: Exception) { manager.close(); throw e }
                        null
                    }
                    "disconnect" -> {
                        val id = required(call, "id")
                        streams.entries.filter { it.value.first == id }.forEach { (key, value) ->
                            streams.remove(key); runCatching { value.second.close() }
                        }
                        connections.remove(id)?.close()
                        null
                    }
                    "open" -> {
                        check(streams.size < 64) { "Too many ADB streams" }
                        val id = required(call, "id")
                        val manager = connections[id] ?: error("ADB disconnected")
                        val stream = manager.openStream(required(call, "service"))
                        val key = sequence.incrementAndGet().toString()
                        streams[key] = Pair(id, stream)
                        key
                    }
                    "read" -> {
                        val stream = streams[required(call, "stream")]?.second ?: error("ADB stream closed")
                        val bytes = ByteArray(32768)
                        val count = try { stream.read(bytes, 0, bytes.size) } catch (e: java.io.IOException) {
                            if (stream.isClosed) -1 else throw e
                        }
                        if (count <= 0) null else bytes.copyOf(count)
                    }
                    "write" -> {
                        val stream = streams[required(call, "stream")]?.second ?: error("ADB stream closed")
                        val bytes = call.argument<ByteArray>("bytes") ?: error("Missing ADB bytes")
                        synchronized(stream) { stream.write(bytes, 0, bytes.size); stream.flush() }
                        null
                    }
                    "close" -> { streams.remove(required(call, "stream"))?.second?.close(); null }
                    else -> { main.post { result.notImplemented() }; return@execute }
                }
                main.post { result.success(answer) }
            } catch (e: Exception) {
                main.post { result.error("adb", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun required(call: MethodCall, key: String): String = call.argument<String>(key) ?: error("Missing $key")

    companion object {
        private val main = Handler(Looper.getMainLooper())
        private fun localAddress(host: InetAddress): Boolean = host.isLoopbackAddress ||
            Collections.list(NetworkInterface.getNetworkInterfaces()).any { it.inetAddresses.toList().contains(host) }

        @Suppress("DEPRECATION")
        fun discover(context: Context, local: Boolean, pairing: Boolean, done: (List<Map<String, Any>>) -> Unit) {
            val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
            val found = mutableListOf<Map<String, Any>>()
            var active = true
            var resolving = false
            val queue = java.util.ArrayDeque<NsdServiceInfo>()
            lateinit var resolveNext: () -> Unit
            resolveNext = resolve@ {
                if (!active || resolving || queue.isEmpty()) return@resolve
                resolving = true
                val info = queue.removeFirst()
                manager.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                        main.post { resolving = false; resolveNext() }
                    }
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        main.post {
                            resolving = false
                            val host = info.host
                            val address = host?.hostAddress
                            if (active && host != null && address != null && (!local || localAddress(host))) {
                                if (found.none { it["name"] == info.serviceName && it["host"] == address }) {
                                    found.add(mapOf("name" to info.serviceName, "host" to address, "port" to info.port))
                                }
                            }
                            resolveNext()
                        }
                    }
                })
            }
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {}
                override fun onDiscoveryStopped(type: String) {}
                override fun onStartDiscoveryFailed(type: String, code: Int) {}
                override fun onStopDiscoveryFailed(type: String, code: Int) {}
                override fun onServiceLost(info: NsdServiceInfo) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    main.post {
                        if (active) { queue.add(info); resolveNext() }
                    }
                }
            }
            try { manager.discoverServices(if (pairing) "_adb-tls-pairing._tcp." else "_adb-tls-connect._tcp.", NsdManager.PROTOCOL_DNS_SD, listener) }
            catch (_: Exception) { active = false; done(emptyList()); return }
            main.postDelayed({
                active = false
                runCatching { manager.stopServiceDiscovery(listener) }
                queue.clear()
                done(found.toList())
            }, 3500)
        }
    }
}
