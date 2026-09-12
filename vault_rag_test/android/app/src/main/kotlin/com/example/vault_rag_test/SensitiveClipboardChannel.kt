package com.example.vault_rag_test

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * `vault/clipboard` — the two clipboard operations Flutter's own Clipboard
 * API cannot express.
 *
 *  - `setSensitiveText`: marks the clip with EXTRA_IS_SENSITIVE, so Android
 *    13+ masks it in the "copied" preview overlay instead of rendering the
 *    capsule JSON on screen for anyone looking over a shoulder. It does not
 *    stop an app with clipboard access (Office Kit included) from reading
 *    the text — nothing can, and VaultLink depends on it being read.
 *  - `clear`: ClipboardManager.clearPrimaryClip() (API 28+), which removes
 *    the clip rather than replacing it with an empty string that clipboard
 *    managers still record as a new entry.
 *
 * The Dart side decides *whether* to clear (only when the clip still equals
 * what Vault wrote); this class only executes.
 */
class SensitiveClipboardChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "vault/clipboard").apply {
        setMethodCallHandler(this@SensitiveClipboardChannel)
    }

    private val clipboard: ClipboardManager
        get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSensitiveText" -> {
                val text = call.arguments as? String
                if (text == null) {
                    result.error("BAD_ARGS", "Expected a string", null)
                    return
                }
                val clip = ClipData.newPlainText("Vault capsule", text)
                clip.description.extras = PersistableBundle().apply {
                    val key = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ClipDescription.EXTRA_IS_SENSITIVE
                    } else {
                        "android.content.extra.IS_SENSITIVE"
                    }
                    putBoolean(key, true)
                }
                clipboard.setPrimaryClip(clip)
                result.success(null)
            }
            "clear" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    clipboard.clearPrimaryClip()
                } else {
                    clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
