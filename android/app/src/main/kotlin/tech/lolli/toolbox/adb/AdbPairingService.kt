package tech.lolli.toolbox.adb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.util.concurrent.Executors

/** A short-lived, user-started local pairing flow, including notification reply. */
class AdbPairingService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var active = true
    private var pairing = false
    private var endpoint: Map<String, Any>? = null
    private val notificationManager get() = getSystemService(NotificationManager::class.java)

    override fun onCreate() {
        super.onCreate()
        notificationManager.createNotificationChannel(NotificationChannel(CHANNEL, "Wireless ADB", NotificationManager.IMPORTANCE_DEFAULT))
        state = "searching"
        startForeground(NOTIFICATION, notification("Open Wireless debugging → Pair device with pairing code"))
        main.postDelayed({ if (active) { state = "timeout"; stopSelf() } }, 120_000)
        discover()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "stop" -> { state = "cancelled"; stopSelf() }
            "reply" -> {
                val code = RemoteInput.getResultsFromIntent(intent)?.getCharSequence("code")?.toString().orEmpty()
                val target = endpoint
                if (!pairing && target != null && code.matches(Regex("[0-9]{6}"))) {
                    pairing = true
                    state = "pairing"
                    notificationManager.notify(NOTIFICATION, notification("Pairing…"))
                    worker.execute {
                        val manager = DeviceAdbManager(applicationContext)
                        try {
                            check(manager.pair(target["host"] as String, target["port"] as Int, code)) { "Pairing rejected" }
                            if (active) {
                                state = "paired"
                                main.post { if (active) stopSelf() }
                            }
                        } catch (_: Exception) {
                            if (active) {
                                state = "rejected"
                                main.post { if (active) { pairing = false; endpoint = null; discover() } }
                            }
                        } finally { manager.close() }
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun discover() {
        if (!active || pairing) return
        AdbBridge.discover(this, true, true) { services ->
            if (!active || pairing) return@discover
            endpoint = services.firstOrNull()
            if (endpoint != null) {
                state = "code_required"
                notificationManager.notify(NOTIFICATION, notification("Enter the six-digit pairing code", reply = true))
            }
            main.postDelayed({ discover() }, 2000)
        }
    }

    private fun notification(text: String, reply: Boolean = false): Notification {
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("ServerBox · Wireless ADB")
            .setContentText(text).setOngoing(true).setOnlyAlertOnce(true)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val stop = PendingIntent.getService(this, 0, Intent(this, javaClass).setAction("stop"), flags)
        builder.addAction(Notification.Action.Builder(null, "Cancel", stop).build())
        if (reply) {
            val pending = PendingIntent.getForegroundService(this, 1, Intent(this, javaClass).setAction("reply"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            builder.addAction(Notification.Action.Builder(null, "Pair", pending)
                .addRemoteInput(RemoteInput.Builder("code").setLabel("Pairing code").build()).build())
        }
        return builder.build()
    }

    override fun onDestroy() {
        active = false
        main.removeCallbacksAndMessages(null)
        if (state == "searching" || state == "pairing" || state == "code_required") state = "cancelled"
        stopForeground(STOP_FOREGROUND_REMOVE)
        worker.shutdown()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    companion object {
        @Volatile var state = "idle"
        private const val CHANNEL = "serverbox_adb_pairing"
        private const val NOTIFICATION = 7312
    }
}
