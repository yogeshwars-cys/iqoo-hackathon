package com.example.vault_rag_test

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.Backend
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * MediaPipe LLM Inference, exposed to Dart as `vault/llm`.
 *
 * Three methods: load, generate, close. The Dart side owns all the policy
 * (which backend to try first, how to recover, what to tell the user); this
 * is deliberately a thin, dumb wrapper, so that the decisions live in one
 * readable place rather than split across two languages.
 *
 * THREADING
 *
 * LlmInference.createFromOptions loads well over a gigabyte from storage
 * and generateResponse blocks for seconds. Both run on a single-thread
 * executor rather than the platform thread: blocking the platform thread
 * stops Flutter servicing *any* channel, so the UI would freeze completely
 * — no progress indicator, no cancel, nothing — for the whole load.
 *
 * A single thread rather than a pool, because the session is not safe to
 * drive concurrently. Dart already serialises calls, and this is the
 * backstop for that being wrong.
 *
 * MethodChannel.Result must be answered on the main thread, hence the
 * Handler round-trip on the way back.
 *
 * WHAT THIS LAYER CAN AND CANNOT DO ABOUT THE BACKEND-MISMATCH CRASH
 *
 * Cannot: catch it. Handing CPU-quantised weights to the GPU backend faults
 * inside native code. SIGSEGV is delivered to the process, not thrown up the
 * JNI boundary, so `catch (e: Throwable)` never sees it — the catch below is
 * for the recoverable case, a GPU init that fails loudly, and it genuinely
 * does catch those. Anyone reading that catch and concluding the crash is
 * handled here is reading it wrong.
 *
 * Can, and now does: refuse to invent a backend when Dart did not name one
 * (see onLoad), and leave a logcat breadcrumb immediately before the call
 * that might not return. Those are the only two moves available. Everything
 * else about avoiding the crash has to happen before this point, in the Dart
 * policy layer, because by the time control is here the decision is already
 * made and the next line either returns or ends the process.
 */
class LlmChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "vault/llm").apply {
        setMethodCallHandler(this@LlmChannel)
    }

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "vault-llm").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var inference: LlmInference? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> onLoad(call, result)
            "generate" -> onGenerate(call, result)
            "close" -> {
                worker.execute { releaseInference() }
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

        // Parsed strictly, with no default.
        //
        // This used to read `call.argument<String>("backend") ?: "gpu"`, with
        // the mapping below written as `if (name == "cpu") CPU else GPU`.
        // Between them that is a second GPU-first default, hidden a language
        // away from the Dart policy that is supposed to own this decision: a
        // missing argument, a typo, or a future enum rename would all land
        // silently on GPU. GPU is the one value that can kill the process on
        // the wrong weights, so it is the one value that must never be
        // reached by accident. An unrecognised backend is now a refused call
        // with a message, which is a bug report; guessing GPU is a SIGSEGV,
        // which is not.
        val requestedBackend = call.argument<String>("backend")
        val backend = when (requestedBackend) {
            "cpu" -> Backend.CPU
            "gpu" -> Backend.GPU
            else -> null
        }
        if (backend == null) {
            result.error(
                "BAD_ARGS",
                "Backend must be \"cpu\" or \"gpu\", got ${requestedBackend ?: "nothing"}.",
                null
            )
            return
        }

        val maxTokens = call.argument<Int>("maxTokens") ?: 1024

        worker.execute {
            try {
                val file = File(path)
                if (!file.canRead()) {
                    // Distinguished from a load failure on purpose: the fix
                    // is completely different, and "cannot read" is by far
                    // the more common of the two.
                    reply(result) {
                        it.error(
                            "UNREADABLE",
                            "Cannot read $path. Files under /data/local/tmp " +
                                "are not readable by an app on most ROMs.",
                            null
                        )
                    }
                    return@execute
                }

                releaseInference()

                val options = LlmInference.LlmInferenceOptions.builder()
                    .setModelPath(path)
                    .setMaxTokens(maxTokens)
                    .setPreferredBackend(backend)
                    .build()

                // Logged BEFORE the call, and deliberately not after.
                //
                // createFromOptions on mismatched weights does not throw — it
                // segfaults inside libllm_inference_engine_jni.so and the
                // process is gone before any catch, any reply, or any Dart
                // code runs. The only thing that survives is what already
                // reached logcat. So this line is the entire post-mortem: a
                // crash report whose last vault line is an "attempting" with
                // no matching "loaded" names the file and the backend that
                // killed it. Do not move it below the call or fold the two
                // into one message.
                Log.i(TAG, "attempting load backend=$requestedBackend path=$path")
                inference = LlmInference.createFromOptions(applicationContext, options)
                Log.i(TAG, "loaded backend=$requestedBackend")
                reply(result) { it.success(null) }
            } catch (e: Throwable) {
                // Throwable, not Exception: a failed GPU init surfaces as an
                // UnsatisfiedLinkError or an Error subclass often enough that
                // catching Exception alone lets the process die on a case the
                // Dart side is designed to recover from by trying CPU.
                releaseInference()
                reply(result) {
                    it.error("LOAD_FAILED", e.message ?: e.toString(), null)
                }
            }
        }
    }

    private fun onGenerate(call: MethodCall, result: MethodChannel.Result) {
        val prompt = call.argument<String>("prompt")
        if (prompt.isNullOrBlank()) {
            result.error("BAD_ARGS", "Empty prompt.", null)
            return
        }

        worker.execute {
            val engine = inference
            if (engine == null) {
                reply(result) {
                    it.error("NOT_LOADED", "No model is loaded.", null)
                }
                return@execute
            }

            try {
                val text = engine.generateResponse(prompt)
                val tokens = try {
                    engine.sizeInTokens(text)
                } catch (e: Throwable) {
                    // Reported as null rather than estimated. A guessed token
                    // count ends up in a capsule's provenance block, where a
                    // wrong number is worse than an absent one.
                    null
                }
                reply(result) {
                    it.success(mapOf("text" to text, "tokens" to tokens))
                }
            } catch (e: Throwable) {
                reply(result) {
                    it.error("GENERATE_FAILED", e.message ?: e.toString(), null)
                }
            }
        }
    }

    private fun releaseInference() {
        try {
            inference?.close()
        } catch (e: Throwable) {
            // Already gone, or native teardown objected. Either way the
            // reference must be dropped or the next load leaks a session.
        }
        inference = null
    }

    private inline fun reply(
        result: MethodChannel.Result,
        crossinline block: (MethodChannel.Result) -> Unit
    ) = main.post { block(result) }

    fun dispose() {
        channel.setMethodCallHandler(null)
        worker.execute { releaseInference() }
        worker.shutdown()
    }

    companion object {
        private const val TAG = "vault-llm"

        /**
         * Set by MainActivity before the channel is constructed.
         *
         * LlmInference.createFromOptions needs a Context and the worker
         * thread has none. The application context is process-scoped and
         * outlives every activity, so holding it here leaks nothing.
         */
        lateinit var applicationContext: android.content.Context
    }
}
