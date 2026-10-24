package tech.kirikira.kiribox.adb

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle

/**
 * Host side of scrcpy clipboard sync. Main thread only. It outlives screen sessions,
 * so reopening the page does not push an unchanged host clip over the target's newer one.
 */
internal class ScrcpyClipboard(context: Context) {
    private val manager = context.getSystemService(ClipboardManager::class.java)
    private var lastText: String? = null
    private var lastStamp = 0L

    fun addListener(listener: ClipboardManager.OnPrimaryClipChangedListener) { manager?.addPrimaryClipChangedListener(listener) }
    fun removeListener(listener: ClipboardManager.OnPrimaryClipChangedListener) { manager?.removePrimaryClipChangedListener(listener) }

    /** Host text the target has not seen yet, or null. Null too while the app lacks focus (Android 10+). */
    fun takeHostChange(): String? {
        val manager = manager ?: return null
        val description = runCatching { manager.primaryClipDescription }.getOrNull() ?: return null
        // The description is readable without Android 12's "pasted" toast; the clip is not.
        val stamp = if (Build.VERSION.SDK_INT >= 26) description.timestamp else 0L
        if (stamp != 0L && stamp == lastStamp) return null
        if (sensitive(description)) { lastStamp = stamp; return null }
        val text = runCatching { manager.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString() }.getOrNull() ?: return null
        lastStamp = stamp
        if (text == lastText) return null
        lastText = text
        return text
    }

    /** Device text placed on the host clipboard; remembered so it is not sent back. */
    fun fromDevice(text: String) {
        val manager = manager ?: return
        if (text == lastText) return
        lastText = text
        runCatching { manager.setPrimaryClip(ClipData.newPlainText("KiriBox", text)) }
        if (Build.VERSION.SDK_INT >= 26) lastStamp = runCatching { manager.primaryClipDescription?.timestamp }.getOrNull() ?: lastStamp
    }

    // Password managers mark their clips; those are not sent to another phone automatically.
    private fun sensitive(description: ClipDescription): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val extras: PersistableBundle = description.extras ?: return false
        return extras.getBoolean("android.content.extra.IS_SENSITIVE", false)
    }
}
