package com.example.vault_rag_test

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * `vault/qnn` — facts the Dart side needs to bring up the QNN HTP delegate
 * for MiniLM, and the delegate's own evidence of what it did.
 *
 * The delegate itself is created in native code (vault_qnn_delegate.cpp)
 * and attached from Dart FFI; this channel never touches it.
 *
 *  - `environment`: native library dir (skel_library_dir), a cache dir for
 *    compiled HTP graphs, which Hexagon skels are actually packaged, whether
 *    the vendor FastRPC library is present on this device, and the SoC as
 *    Build reports it. Reporting only — nothing here decides "NPU present".
 *  - `delegationReport`: the QNN delegate logs
 *    "<name> delegate: N nodes delegated out of M nodes with P partitions."
 *    at INFO level. An app may read its own process's log lines, so this
 *    returns that line verbatim, parsed. It is the runtime's statement of
 *    graph coverage — the acceptance check uses it instead of guessing.
 */
class QnnChannel(
    messenger: BinaryMessenger,
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "vault/qnn").apply {
        setMethodCallHandler(this@QnnChannel)
    }
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "vault-qnn").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    private val delegationLine =
        Regex("""(\S+) delegate: (\d+) nodes delegated out of (\d+) nodes with (\d+) partitions""")

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "environment" -> run(result) { environment() }
            "delegationReport" -> {
                val since = (call.argument<Number>("sinceEpochMs"))?.toLong() ?: 0L
                run(result) { delegationReport(since) }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, op: () -> Any?) {
        worker.execute {
            try {
                val value = op()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post { result.error("QNN_CHANNEL", e.javaClass.simpleName, e.message) }
            }
        }
    }

    private fun environment(): Map<String, Any?> {
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val libs = File(nativeDir).list()?.toList() ?: emptyList()
        val cache = File(context.codeCacheDir, "qnn_htp_cache").apply { mkdirs() }
        val fastRpcPaths = listOf(
            "/vendor/lib64/libcdsprpc.so",
            "/system/vendor/lib64/libcdsprpc.so",
            "/odm/lib64/libcdsprpc.so",
        )
        return mapOf(
            "nativeLibraryDir" to nativeDir,
            "cacheDir" to cache.absolutePath,
            "qnnRuntimeVersion" to BuildConfig.QNN_RUNTIME_VERSION,
            "delegateLibraryPackaged" to libs.contains("libQnnTFLiteDelegate.so"),
            "htpLibraryPackaged" to libs.contains("libQnnHtp.so"),
            "shimPackaged" to libs.contains("libvault_qnn_delegate.so"),
            "skels" to libs.filter { it.startsWith("libQnnHtpV") && it.endsWith("Skel.so") }.sorted(),
            // Presence of the vendor file only; whether the app's linker
            // namespace may load it depends on the manifest declaration and
            // is proven only by the delegate actually starting.
            "fastRpcLibraryPresent" to fastRpcPaths.any { File(it).exists() },
            "socManufacturer" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MANUFACTURER else null,
            "socModel" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Build.SOC_MODEL else null,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    private fun delegationReport(sinceEpochMs: Long): Map<String, Any?> {
        val since = String.format(java.util.Locale.US, "%d.%03d", sinceEpochMs / 1000, sinceEpochMs % 1000)
        val process = ProcessBuilder(
            "logcat", "-d", "-v", "epoch", "--pid", Process.myPid().toString(), "-T", since,
        ).redirectErrorStream(true).start()
        val lines = process.inputStream.bufferedReader().readLines()
        process.waitFor()

        // Delegate, shim, LiteRT and FastRPC lines only — enough to explain a
        // failed interpreter build, and none of these components log user text.
        val markers = listOf("[Qnn Delegate]", "vault_qnn", " tflite", "QnnDsp", "QnnHtp")
        val rpcMarkers = listOf("adsprpc", "fastrpc", "remote_handle", "apps_std")
        val qnnLines = lines.filter { line ->
            markers.any { line.contains(it) } ||
                rpcMarkers.any { line.contains(it, ignoreCase = true) }
        }
        val match = qnnLines.asReversed().firstNotNullOfOrNull { delegationLine.find(it) }
        return mapOf(
            "found" to (match != null),
            "delegateName" to match?.groupValues?.get(1),
            "nodesDelegated" to match?.groupValues?.get(2)?.toInt(),
            "nodesTotal" to match?.groupValues?.get(3)?.toInt(),
            "partitions" to match?.groupValues?.get(4)?.toInt(),
            // Bounded: enough to diagnose a failure without shipping the log.
            "lines" to qnnLines.takeLast(40),
        )
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
