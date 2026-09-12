package com.example.vault_rag_test

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * llama.cpp, exposed to Dart as `vault/llama`.
 *
 * The GGUF/llama.cpp path alongside `vault/llm` (MediaPipe/Gemma), not in
 * place of it — see llm_runtime.dart and the PocketRAG plan this implements
 * for why the existing path stays as the proven fallback.
 *
 * Threading and error-handling follow [LlmChannel]'s pattern exactly: one
 * daemon worker thread (the llama.cpp session is no more safe to drive
 * concurrently than a MediaPipe one), replies posted back through a
 * [Handler] because [MethodChannel.Result] must be answered on the main
 * thread, and `catch (e: Throwable)` around every native call.
 *
 * ONE REAL DIFFERENCE FROM [LlmChannel]'S CRASH STORY
 *
 * MediaPipe's crash comes from handing CPU-quantised weights to the GPU
 * backend — two different tensor layouts, same container format, and no way
 * to tell them apart except the filename. GGUF has no such split: one file
 * format, one set of weights, and [LlamaEngine.nativeLoad] resolves "cpu" /
 * "gpu" / "npu" to a specific `ggml_backend_dev_t` by name (see
 * vault_llama_jni.cpp's `select_device`) rather than by guessing from a
 * quantisation the file doesn't actually encode. An unavailable device is a
 * clean, catchable `LOAD_FAILED` here — not a process death — because
 * llama.cpp's backend selection was designed to be queried, not gambled on.
 */
class LlamaChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "vault/llama").apply {
        setMethodCallHandler(this@LlamaChannel)
    }

    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vault-llama").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var loaded = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> onLoad(call, result)
            "generate" -> onGenerate(call, result)
            "backendStatus" -> onBackendStatus(result)
            "close" -> {
                worker.execute { runCatching { LlamaEngine.nativeUnload() }; loaded = false }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun onLoad(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("BAD_ARGS", "No model path supplied.", null)
            return
        }

        // Same discipline as LlmChannel.onLoad: parsed strictly, no default
        // that could silently pick a backend nobody asked for.
        val device = call.argument<String>("device")
        if (device != "cpu" && device != "gpu" && device != "npu") {
            result.error(
                "BAD_ARGS",
                "device must be \"cpu\", \"gpu\" or \"npu\", got ${device ?: "nothing"}.",
                null,
            )
            return
        }

        val nCtx = call.argument<Int>("nCtx") ?: 4096
        val temperature = (call.argument<Double>("temperature") ?: 0.2).toFloat()
        val topK = call.argument<Int>("topK") ?: 40

        worker.execute {
            try {
                LlamaEngine.nativeInit(applicationContext.applicationInfo.nativeLibraryDir)

                Log.i(TAG, "attempting load device=$device path=$path nCtx=$nCtx")
                val code = LlamaEngine.nativeLoad(path, nCtx, device, temperature, topK)
                if (code != 0) {
                    loaded = false
                    val message = when (code) {
                        1 -> "The model file could not be loaded — check it is a valid GGUF file."
                        2 -> "No \"$device\" device is available on this build. " +
                            "Rebuild with the matching backend enabled and reinstall."
                        3 -> "Failed to create an inference context for nCtx=$nCtx " +
                            "— most likely not enough memory for this context size."
                        else -> "Load failed with code $code."
                    }
                    reply(result) { it.error("LOAD_FAILED", message, code) }
                    return@execute
                }

                loaded = true
                Log.i(TAG, "loaded device=$device")
                reply(result) { it.success(parseJsonToMap(LlamaEngine.nativeBackendStatus())) }
            } catch (e: Throwable) {
                loaded = false
                reply(result) { it.error("LOAD_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun onGenerate(call: MethodCall, result: MethodChannel.Result) {
        val prompt = call.argument<String>("prompt")
        if (prompt.isNullOrBlank()) {
            result.error("BAD_ARGS", "Empty prompt.", null)
            return
        }
        val maxTokens = call.argument<Int>("maxTokens") ?: 512

        worker.execute {
            if (!loaded) {
                reply(result) { it.error("NOT_LOADED", "No model is loaded.", null) }
                return@execute
            }
            try {
                val json = JSONObject(LlamaEngine.nativeGenerate(prompt, maxTokens))
                if (json.has("error")) {
                    reply(result) {
                        it.error("GENERATE_FAILED", json.optString("error"), jsonToMap(json))
                    }
                    return@execute
                }
                reply(result) { it.success(jsonToMap(json)) }
            } catch (e: Throwable) {
                reply(result) { it.error("GENERATE_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun onBackendStatus(result: MethodChannel.Result) {
        worker.execute {
            try {
                LlamaEngine.nativeInit(applicationContext.applicationInfo.nativeLibraryDir)
                reply(result) { it.success(parseJsonToMap(LlamaEngine.nativeBackendStatus())) }
            } catch (e: Throwable) {
                reply(result) { it.error("STATUS_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun parseJsonToMap(raw: String): Map<String, Any?> = jsonToMap(JSONObject(raw))

    /** Shallow JSON object -> Map, plus one level of array-of-objects — all this wrapper's own JSON ever nests. */
    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.get(key)
            map[key] = when (value) {
                is JSONObject -> jsonToMap(value)
                is org.json.JSONArray -> (0 until value.length()).map { i ->
                    val item = value.get(i)
                    if (item is JSONObject) jsonToMap(item) else item
                }
                JSONObject.NULL -> null
                else -> value
            }
        }
        return map
    }

    private inline fun reply(
        result: MethodChannel.Result,
        crossinline block: (MethodChannel.Result) -> Unit,
    ) = main.post { block(result) }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.execute { runCatching { LlamaEngine.nativeUnload() } }
        worker.shutdown()
    }

    companion object {
        private const val TAG = "vault-llama"

        /** Set by MainActivity before this channel is constructed. See [LlmChannel]'s identical field. */
        lateinit var applicationContext: android.content.Context
    }
}
