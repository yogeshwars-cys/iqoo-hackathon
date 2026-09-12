package com.example.vault_rag_test

/**
 * Raw JNI bindings to `vault_llama_jni.cpp`.
 *
 * Deliberately not the class [LlamaChannel] talks to Flutter through — same
 * separation [LlmChannel] draws from MediaPipe's Java API: this is the
 * "what the native library actually exposes" layer, thin enough that
 * [LlamaChannel] can own all the threading/error-mapping policy in one
 * place, matching that file's own reasoning.
 *
 * Methods are bound via `JNI_OnLoad` + `RegisterNatives` in
 * vault_llama_jni.cpp, not the `Java_pkg_Class_method` naming convention —
 * this package name contains underscores, which that convention encodes as
 * literal `_1` escapes easy to get wrong with no compiler to catch it.
 * [System.loadLibrary] still has to run first to trigger `JNI_OnLoad`.
 */
internal object LlamaEngine {
    init {
        System.loadLibrary("vault_llama")
    }

    external fun nativeInit(nativeLibDir: String)

    /**
     * Returns 0 on success, matching vault_llama_jni.cpp's op_load:
     *   1 = model file failed to load/parse
     *   2 = requested device ("gpu" | "npu") not available on this build
     *   3 = context creation failed (most likely OOM for nCtx)
     */
    external fun nativeLoad(
        modelPath: String,
        nCtx: Int,
        device: String,
        temperature: Float,
        topK: Int,
    ): Int

    /**
     * Returns a JSON object string: `{"text","tokens","prefill_ms","decode_ms"}`
     * on success, `{"error"}` (optionally with extra fields) on failure.
     * Never throws — every native failure path is a clean return, since
     * there is no JNI exception for [LlamaChannel] to catch if it were not.
     */
    external fun nativeGenerate(prompt: String, maxTokens: Int): String

    external fun nativeUnload()

    /** `{"loaded_backend", "devices": [{"name","description","type"}]}` */
    external fun nativeBackendStatus(): String

    external fun nativeSystemInfo(): String
}
