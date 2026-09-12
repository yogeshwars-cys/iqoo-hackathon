package com.example.vault_rag_test

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Everything the telemetry layer needs that procfs cannot supply.
 *
 * The Dart side reads /proc and /sys directly, which covers CPU, GPU and
 * memory without any native code. Two things are not in sysfs at all on a
 * production build, and both matter for benchmarking:
 *
 *  - SoC identity. Build.SOC_MODEL is the only reliable source. Knowing a
 *    result came from an SM6375 rather than an SM8650 is the difference
 *    between a benchmark and a number.
 *
 *  - Thermal throttling state. PowerManager.getCurrentThermalStatus() is
 *    the platform's own answer to "is this device being held back right
 *    now", and there is no sysfs equivalent an app can read. Without it a
 *    benchmark cannot distinguish a slow run from a throttled one, which is
 *    the single most common way phone benchmarks mislead.
 *
 * Both are version-gated: SOC_MODEL is API 31+, thermal status is API 29+,
 * and this app's minSdk is lower than either. Missing values come back as
 * null and the UI renders them as unknown rather than guessing.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "vault/device"
    private var llmChannel: LlmChannel? = null
    private var llamaChannel: LlamaChannel? = null
    private var keystoreChannel: KeystoreChannel? = null
    private var clipboardChannel: SensitiveClipboardChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // The LLM worker thread needs a Context and has no activity. The
        // application context is process-scoped, so this leaks nothing.
        LlmChannel.applicationContext = applicationContext
        llmChannel = LlmChannel(flutterEngine.dartExecutor.binaryMessenger)

        LlamaChannel.applicationContext = applicationContext
        llamaChannel = LlamaChannel(flutterEngine.dartExecutor.binaryMessenger)

        // AndroidKeyStore: chunk encryption and capsule signing. See
        // KeystoreChannel.kt for the key specs and the StrongBox/TEE policy.
        keystoreChannel = KeystoreChannel(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        clipboardChannel = SensitiveClipboardChannel(flutterEngine.dartExecutor.binaryMessenger, applicationContext)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceInfo" -> result.success(deviceInfo())
                "thermal" -> result.success(thermalStatus())
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        // Releases the MediaPipe session. Without this a relaunch loads a
        // second copy of a 1.3 GB model alongside the first.
        llmChannel?.dispose()
        llmChannel = null
        llamaChannel?.dispose()
        llamaChannel = null
        keystoreChannel?.dispose()
        keystoreChannel = null
        clipboardChannel?.dispose()
        clipboardChannel = null
        super.onDestroy()
    }

    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "hardware" to Build.HARDWARE,
        "androidRelease" to Build.VERSION.RELEASE,
        "sdkInt" to Build.VERSION.SDK_INT,
        "socManufacturer" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER
        } else null,
        "socModel" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL
        } else null,
        "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
        "totalMemMb" to totalMemoryMb()
    )

    private fun totalMemoryMb(): Long? = try {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.totalMem / (1024 * 1024)
    } catch (e: Exception) {
        null
    }

    /**
     * Returns the thermal headroom situation, or null below API 29.
     *
     * `status` is PowerManager's 0..6 scale (NONE through SHUTDOWN).
     * Anything at or above LIGHT (1) means the platform is actively
     * limiting performance, which invalidates a benchmark taken during it.
     */
    private fun thermalStatus(): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val status = pm.currentThermalStatus
            mapOf(
                "status" to status,
                "label" to when (status) {
                    PowerManager.THERMAL_STATUS_NONE -> "none"
                    PowerManager.THERMAL_STATUS_LIGHT -> "light"
                    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                    PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
                    else -> "unknown"
                },
                "throttling" to (status >= PowerManager.THERMAL_STATUS_LIGHT)
            )
        } catch (e: Exception) {
            null
        }
    }
}
