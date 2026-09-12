/// vault_llama_jni.cpp
///
/// Thin JNI wrapper around llama.cpp's C API, driving the model/context/
/// sampler lifecycle exactly the way llama.cpp's own reference Android
/// integration (examples/llama.android in the vendored submodule) does —
/// this file adapts that proven load/decode/sample/detokenize sequence
/// rather than re-deriving it, since there is no device available in the
/// environment that wrote this to verify a hand-rolled version against.
///
/// WHAT'S DELIBERATELY SIMPLER THAN THE REFERENCE, AND WHY
///
/// The reference app is a multi-turn chat client: it keeps a persistent KV
/// cache and conversation history across turns, and shifts context (discards
/// the oldest half of it) when the cache fills up. Every capsule query in
/// this app is independent — `LlmRuntime.generate()`/`VaultEngine.ask()`
/// already treat generation as one-shot, with no memory of a previous
/// query — so carrying that complexity over would add a large surface of
/// context-shift bugs for a capability nothing here uses. [nativeGenerate]
/// instead clears the KV cache and rebuilds the sampler at the start of
/// every call, which is the one-shot equivalent of the same idea.
///
/// WHY JNI_OnLoad + RegisterNatives, NOT javah-style name-mangled functions
///
/// The Kotlin class this binds to lives in a package with underscores
/// (`com.example.vault_rag_test`), which the `Java_pkg_Class_method` naming
/// convention encodes as literal `_1` escapes — easy to get wrong, and a
/// mismatch fails at load time with no compiler error to catch it. Explicit
/// registration maps plain function pointers to method names instead, which
/// sidesteps that whole class of mistake — worth the extra boilerplate given
/// nothing here can be run to check the alternative actually linked.
///
/// EXPLICIT DEVICE SELECTION, NOT "JUST OFFLOAD EVERYTHING"
///
/// Adreno OpenCL and Hexagon HTP both register as `GGML_BACKEND_DEVICE_TYPE_
/// GPU` devices in ggml's backend registry — llama.cpp's own docs note "Hexagon
/// NPU behaves as a GPU device". Handing `llama_model_params.devices` a NULL
/// device list would let llama.cpp pick for itself whenever more than one
/// qualifies, which is exactly the kind of silent choice the PocketRAG plan
/// asks this build to avoid ("never report GPU/NPU usage unless the runtime
/// confirms execution", "prevent silent GPU -> CPU fallback"). [select_device]
/// filters explicitly by device name instead, so "gpu" and "npu" can never
/// resolve to each other by accident.

#include <jni.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "chat.h"
#include "common.h"
#include "llama.h"
#include "sampling.h"

#include "logging.h"

namespace {

constexpr int BATCH_SIZE = 512;
constexpr int N_THREADS_MIN = 2;
constexpr int N_THREADS_MAX = 6;
constexpr int N_THREADS_HEADROOM = 2;

// Guards every global below. All calls already arrive serialized from a
// single-thread Kotlin executor (LlamaChannel.kt mirrors LlmChannel.kt's
// worker-thread pattern), so this is a backstop against that invariant being
// violated, not the primary safety mechanism — the same relationship
// VaultEngine's serialisation has to the TFLite interpreter it protects.
std::mutex g_mutex;

llama_model *g_model = nullptr;
llama_context *g_context = nullptr;
llama_batch g_batch{};
common_sampler *g_sampler = nullptr;
common_chat_templates_ptr g_chat_templates;
std::string g_backend_label = "none";
bool g_backend_initialized = false;
// Set at load, reapplied every generate() call — see the sampler-recreation
// comment there for why generate() cannot just keep reusing the sampler
// [op_load] built.
float g_temperature = 0.2f;
int g_top_k = 40;

std::string to_lower(const std::string &s) {
    std::string out = s;
    for (auto &c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

bool contains_ci(const std::string &haystack, const char *needle) {
    return to_lower(haystack).find(needle) != std::string::npos;
}

/// Finds the ggml_backend_dev_t matching [want] ("cpu" | "gpu" | "npu").
///
/// "gpu" and "npu" both scan GGML_BACKEND_DEVICE_TYPE_GPU devices, since
/// that's the type both Adreno/OpenCL and Hexagon/HTP register as — they are
/// told apart only by name, matching on "hexagon"/"htp" for NPU and
/// excluding those same names for GPU. Returns nullptr if this build has no
/// matching device, which the caller turns into a clean, catchable error
/// rather than proceeding on a guess.
ggml_backend_dev_t select_device(const std::string &want) {
    if (want == "cpu") {
        return ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    }

    const size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (ggml_backend_dev_type(dev) != GGML_BACKEND_DEVICE_TYPE_GPU) continue;

        const std::string name = ggml_backend_dev_name(dev);
        const bool is_hexagon = contains_ci(name, "hexagon") || contains_ci(name, "htp");
        if (want == "npu" && is_hexagon) return dev;
        if (want == "gpu" && !is_hexagon) return dev;
    }
    return nullptr;
}

std::string describe_device(ggml_backend_dev_t dev) {
    if (dev == nullptr) return "CPU";
    std::ostringstream out;
    out << ggml_backend_dev_name(dev) << " (" << ggml_backend_dev_description(dev) << ")";
    return out.str();
}

void release_model_locked() {
    if (g_sampler) { common_sampler_free(g_sampler); g_sampler = nullptr; }
    g_chat_templates.reset();
    if (g_batch.token != nullptr || g_batch.embd != nullptr) {
        llama_batch_free(g_batch);
        g_batch = {};
    }
    if (g_context) { llama_free(g_context); g_context = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    g_backend_label = "none";
}

/// Escapes a string for embedding as a JSON string value. Only the
/// characters JSON actually requires escaped — this is not a general JSON
/// writer, just enough to safely carry model output (which is itself
/// frequently JSON, so embedded quotes are the common case, not the edge
/// case) inside this wrapper's own response envelope.
std::string escape_json(const std::string &s) {
    std::ostringstream out;
    for (unsigned char c : s) {
        switch (c) {
            case '"': out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\n': out << "\\n"; break;
            case '\r': out << "\\r"; break;
            case '\t': out << "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out << buf;
                } else {
                    out << static_cast<char>(c);
                }
        }
    }
    return out.str();
}

bool is_valid_utf8_prefix(const std::string &s) {
    const auto *bytes = reinterpret_cast<const unsigned char *>(s.c_str());
    while (*bytes != 0x00) {
        int num;
        if ((*bytes & 0x80) == 0x00) num = 1;
        else if ((*bytes & 0xE0) == 0xC0) num = 2;
        else if ((*bytes & 0xF0) == 0xE0) num = 3;
        else if ((*bytes & 0xF8) == 0xF0) num = 4;
        else return false;
        bytes++;
        for (int i = 1; i < num; i++) {
            if ((*bytes & 0xC0) != 0x80) return false;
            bytes++;
        }
    }
    return true;
}

// ---------------------------------------------------------------------
// JNI-facing operations. Each takes/returns only primitives and strings so
// the registration table below stays simple.
// ---------------------------------------------------------------------

void op_init(JNIEnv *env, jstring j_native_lib_dir) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_backend_initialized) return;

    llama_log_set(vault_llama_android_log_callback, nullptr);

    const char *lib_dir = env->GetStringUTFChars(j_native_lib_dir, nullptr);
    LOGi("loading ggml backends from %s", lib_dir);
    ggml_backend_load_all_from_path(lib_dir);
    env->ReleaseStringUTFChars(j_native_lib_dir, lib_dir);

    llama_backend_init();
    g_backend_initialized = true;
    LOGi("backend initialised: %s", llama_print_system_info());
}

/// Returns 0 on success. Nonzero codes are distinguished so the Kotlin/Dart
/// layers can give a real message instead of "load failed":
///   1 = model file failed to parse/load
///   2 = requested device not available on this build (e.g. "npu" with no
///       Hexagon .so loaded)
///   3 = context creation failed (most likely OOM for the requested n_ctx)
jint op_load(JNIEnv *env, jstring j_model_path, jint n_ctx, jstring j_device,
             jfloat temperature, jint top_k) {
    std::lock_guard<std::mutex> lock(g_mutex);
    release_model_locked();

    const char *model_path = env->GetStringUTFChars(j_model_path, nullptr);
    const char *device_chars = env->GetStringUTFChars(j_device, nullptr);
    const std::string device = to_lower(device_chars);
    env->ReleaseStringUTFChars(j_device, device_chars);

    llama_model_params model_params = llama_model_default_params();
    ggml_backend_dev_t devs[2] = {nullptr, nullptr};

    if (device != "cpu") {
        ggml_backend_dev_t dev = select_device(device);
        if (dev == nullptr) {
            env->ReleaseStringUTFChars(j_model_path, model_path);
            LOGe("no '%s' device available on this build", device.c_str());
            return 2;
        }
        devs[0] = dev;
        model_params.devices = devs;
        model_params.n_gpu_layers = -1; // negative = all layers, per llama.h
        g_backend_label = describe_device(dev);
    } else {
        model_params.n_gpu_layers = 0;
        g_backend_label = "CPU";
    }

    LOGi("loading model from %s on %s", model_path, g_backend_label.c_str());
    g_model = llama_model_load_from_file(model_path, model_params);
    env->ReleaseStringUTFChars(j_model_path, model_path);
    if (g_model == nullptr) {
        LOGe("llama_model_load_from_file returned null");
        return 1;
    }

    const int n_threads = std::max(N_THREADS_MIN,
        std::min(N_THREADS_MAX, (int) std::thread::hardware_concurrency() - N_THREADS_HEADROOM));

    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = (uint32_t) n_ctx;
    ctx_params.n_batch = BATCH_SIZE;
    ctx_params.n_ubatch = BATCH_SIZE;
    ctx_params.n_threads = n_threads;
    ctx_params.n_threads_batch = n_threads;

    g_context = llama_init_from_model(g_model, ctx_params);
    if (g_context == nullptr) {
        LOGe("llama_init_from_model returned null (n_ctx=%d)", n_ctx);
        llama_model_free(g_model);
        g_model = nullptr;
        return 3;
    }

    g_batch = llama_batch_init(BATCH_SIZE, 0, 1);
    g_chat_templates = common_chat_templates_init(g_model, "");

    g_temperature = temperature;
    g_top_k = top_k;
    common_params_sampling sparams;
    sparams.temp = g_temperature;
    sparams.top_k = g_top_k;
    g_sampler = common_sampler_init(g_model, sparams);

    LOGi("model ready: n_ctx=%d threads=%d backend=%s", n_ctx, n_threads, g_backend_label.c_str());
    return 0;
}

/// Decodes [tokens] starting at position 0 in fixed-size batches, requesting
/// logits only on the final token of the final batch. Returns false (and
/// logs) on the first llama_decode failure.
bool decode_prompt(const std::vector<llama_token> &tokens) {
    for (size_t i = 0; i < tokens.size(); i += BATCH_SIZE) {
        const size_t chunk = std::min(tokens.size() - i, (size_t) BATCH_SIZE);
        common_batch_clear(g_batch);
        for (size_t j = 0; j < chunk; j++) {
            const bool want_logits = (i + j == tokens.size() - 1);
            common_batch_add(g_batch, tokens[i + j], (llama_pos)(i + j), {0}, want_logits);
        }
        if (llama_decode(g_context, g_batch) != 0) {
            LOGe("llama_decode failed decoding prompt chunk at %zu", i);
            return false;
        }
    }
    return true;
}

/// Returns a JSON string: on success
///   {"text": "...", "tokens": N, "prefill_ms": X, "decode_ms": Y}
/// on failure
///   {"error": "reason"}
/// Never throws past the JNI boundary — every failure path here is a clean
/// return, because the caller (LlamaChannel.kt) has no native exception to
/// catch if this does something else.
std::string op_generate(JNIEnv *env, jstring j_prompt, jint max_tokens) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context == nullptr || g_model == nullptr) {
        return R"({"error":"not_loaded"})";
    }

    const char *prompt_chars = env->GetStringUTFChars(j_prompt, nullptr);
    std::string prompt(prompt_chars);
    env->ReleaseStringUTFChars(j_prompt, prompt_chars);

    // One-shot: no memory of any previous call. See the file header for why
    // this never carries context across generations the way a chat client
    // would.
    llama_memory_clear(llama_get_memory(g_context), false);
    if (g_sampler) common_sampler_free(g_sampler);
    common_params_sampling sparams;
    sparams.temp = g_temperature;
    sparams.top_k = g_top_k;
    g_sampler = common_sampler_init(g_model, sparams);

    const bool has_template = g_chat_templates &&
                               common_chat_templates_was_explicit(g_chat_templates.get());
    std::string formatted = prompt;
    if (has_template) {
        common_chat_msg msg;
        msg.role = "user";
        msg.content = prompt;
        formatted = common_chat_format_single(g_chat_templates.get(), {}, msg, /*add_ass=*/true,
                                               /*use_jinja=*/false);
    }

    const auto prompt_tokens = common_tokenize(g_context, formatted, /*add_special=*/true,
                                                /*parse_special=*/has_template);

    const uint32_t n_ctx = llama_n_ctx(g_context);
    // Same lesson as the MediaPipe path's pre-flight length guard
    // (llm_runtime.dart's generate()): a prompt that doesn't fit the
    // session's context is refused here, not handed to llama_decode(),
    // because that failure mode is a crash risk, not a clean error.
    if (prompt_tokens.size() + 8 >= n_ctx) {
        LOGe("prompt too long: %zu tokens against n_ctx=%u", prompt_tokens.size(), n_ctx);
        std::ostringstream err;
        err << R"({"error":"prompt_too_long","prompt_tokens":)" << prompt_tokens.size()
            << R"(,"n_ctx":)" << n_ctx << "}";
        return err.str();
    }

    const int64_t t_prefill_start = ggml_time_us();
    if (!decode_prompt(prompt_tokens)) {
        return R"({"error":"decode_failed"})";
    }
    const int64_t t_prefill_end = ggml_time_us();

    std::string cached_chars;
    std::ostringstream output;
    int generated = 0;
    llama_pos pos = (llama_pos) prompt_tokens.size();
    const int64_t t_decode_start = ggml_time_us();

    while (generated < max_tokens) {
        const llama_token new_token = common_sampler_sample(g_sampler, g_context, -1);
        common_sampler_accept(g_sampler, new_token, true);

        if (llama_vocab_is_eog(llama_model_get_vocab(g_model), new_token)) {
            break;
        }

        cached_chars += common_token_to_piece(g_context, new_token);
        if (is_valid_utf8_prefix(cached_chars)) {
            output << cached_chars;
            cached_chars.clear();
        }
        generated++;

        common_batch_clear(g_batch);
        common_batch_add(g_batch, new_token, pos, {0}, true);
        if (llama_decode(g_context, g_batch) != 0) {
            LOGe("llama_decode failed generating token %d", generated);
            break;
        }
        pos++;
    }
    const int64_t t_decode_end = ggml_time_us();

    std::ostringstream json;
    json << "{\"text\":\"" << escape_json(output.str()) << "\","
         << "\"tokens\":" << generated << ","
         << "\"prefill_ms\":" << (t_prefill_end - t_prefill_start) / 1000 << ","
         << "\"decode_ms\":" << (t_decode_end - t_decode_start) / 1000 << "}";
    return json.str();
}

void op_unload() {
    std::lock_guard<std::mutex> lock(g_mutex);
    release_model_locked();
}

std::string op_backend_status() {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::ostringstream json;
    json << "{\"loaded_backend\":\"" << escape_json(g_backend_label) << "\",\"devices\":[";
    const size_t count = ggml_backend_dev_count();
    for (size_t i = 0; i < count; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        const char *type = "unknown";
        switch (ggml_backend_dev_type(dev)) {
            case GGML_BACKEND_DEVICE_TYPE_CPU:   type = "cpu"; break;
            case GGML_BACKEND_DEVICE_TYPE_GPU:   type = "gpu"; break;
            case GGML_BACKEND_DEVICE_TYPE_IGPU:  type = "igpu"; break;
            case GGML_BACKEND_DEVICE_TYPE_ACCEL: type = "accel"; break;
            default: break;
        }
        if (i > 0) json << ",";
        json << "{\"name\":\"" << escape_json(ggml_backend_dev_name(dev)) << "\","
             << "\"description\":\"" << escape_json(ggml_backend_dev_description(dev)) << "\","
             << "\"type\":\"" << type << "\"}";
    }
    json << "]}";
    return json.str();
}

// ---------------------------------------------------------------------
// JNI plumbing
// ---------------------------------------------------------------------

jstring to_jstring(JNIEnv *env, const std::string &s) {
    return env->NewStringUTF(s.c_str());
}

void jni_init(JNIEnv *env, jobject, jstring native_lib_dir) {
    op_init(env, native_lib_dir);
}

jint jni_load(JNIEnv *env, jobject, jstring model_path, jint n_ctx, jstring device,
              jfloat temperature, jint top_k) {
    return op_load(env, model_path, n_ctx, device, temperature, top_k);
}

jstring jni_generate(JNIEnv *env, jobject, jstring prompt, jint max_tokens) {
    return to_jstring(env, op_generate(env, prompt, max_tokens));
}

void jni_unload(JNIEnv *, jobject) {
    op_unload();
}

jstring jni_backend_status(JNIEnv *env, jobject) {
    return to_jstring(env, op_backend_status());
}

jstring jni_system_info(JNIEnv *env, jobject) {
    return to_jstring(env, std::string(llama_print_system_info()));
}

const JNINativeMethod kMethods[] = {
    {"nativeInit", "(Ljava/lang/String;)V", (void *) jni_init},
    {"nativeLoad", "(Ljava/lang/String;ILjava/lang/String;FI)I", (void *) jni_load},
    {"nativeGenerate", "(Ljava/lang/String;I)Ljava/lang/String;", (void *) jni_generate},
    {"nativeUnload", "()V", (void *) jni_unload},
    {"nativeBackendStatus", "()Ljava/lang/String;", (void *) jni_backend_status},
    {"nativeSystemInfo", "()Ljava/lang/String;", (void *) jni_system_info},
};

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    jclass cls = env->FindClass("com/example/vault_rag_test/LlamaEngine");
    if (cls == nullptr) {
        LOGe("FindClass failed for com.example.vault_rag_test.LlamaEngine");
        return JNI_ERR;
    }

    if (env->RegisterNatives(cls, kMethods, sizeof(kMethods) / sizeof(kMethods[0])) != JNI_OK) {
        LOGe("RegisterNatives failed");
        env->DeleteLocalRef(cls);
        return JNI_ERR;
    }
    env->DeleteLocalRef(cls);

    LOGi("vault_llama native methods registered");
    return JNI_VERSION_1_6;
}
