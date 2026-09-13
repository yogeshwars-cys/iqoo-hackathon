// vault_qnn_delegate.cpp
//
// Creates and destroys Qualcomm's QNN HTP TFLite delegate and hands the raw
// TfLiteDelegate* to Dart (lib/core/qnn/qnn_htp_delegate.dart), which passes
// it to tflite_flutter's InterpreterOptions.addDelegate. Used for the MiniLM
// encoder ONLY — llama.cpp generation never touches the NPU.
//
// WHY THE EXTERNAL-DELEGATE PLUGIN ABI, NOT TfLiteQnnDelegateCreate
//
// libQnnTFLiteDelegate.so (Maven: com.qualcomm.qti:qnn-litert-delegate)
// exports both. TfLiteQnnDelegateCreate takes a TfLiteQnnDelegateOptions
// struct whose layout belongs to one SDK release; compiling against a copied
// header and then linking a different AAR version is a silent memory
// corruption. The plugin ABI —
//
//   TfLiteDelegate* tflite_plugin_create_delegate(char** keys, char** values,
//                                                 size_t count);
//   void tflite_plugin_destroy_delegate(TfLiteDelegate*);
//
// — is TFLite's stable external-delegate contract: string options, parsed
// by the delegate itself, unknown keys reported rather than misread. The
// option names below were read from the 2.50.0 binary and the numeric
// values from the AAR's own Java enums (QnnDelegate$Options$*).
//
// The library is dlopen()ed at runtime, so this shim builds without any
// Qualcomm SDK and a build without the AAR simply reports "unavailable".
//
// NPU BRING-UP ON ANDROID (what has to be true before this can succeed):
//  1. libQnnTFLiteDelegate.so, libQnnHtp.so, libQnnHtpPrepare.so,
//     libQnnSystem.so and libQnnHtpV<arch>Stub.so in the app's native lib dir.
//  2. libQnnHtpV<arch>Skel.so there too, EXTRACTED to disk (the DSP loads it
//     by path via FastRPC) — build.gradle.kts sets useLegacyPackaging.
//  3. <uses-native-library android:name="libcdsprpc.so"> in the manifest, or
//     the stub cannot reach the DSP on Android 12+.
//  4. ADSP_LIBRARY_PATH / skel_library_dir pointing at the native lib dir,
//     set before the first FastRPC session in the process.
//  5. An unsigned protection domain (default on Snapdragon 8 Gen 2 and
//     later, including SM8850) — no Qualcomm signing is needed.

#include <android/log.h>
#include <dlfcn.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

#define LOG_TAG "vault_qnn"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

using CreateFn = void *(*)(char **, char **, size_t);
using DestroyFn = void (*)(void *);

std::mutex g_mutex;
void *g_lib = nullptr;
CreateFn g_create = nullptr;
DestroyFn g_destroy = nullptr;
std::string g_native_dir;
thread_local std::string t_last_error;

void set_error(const std::string &msg) {
    t_last_error = msg;
    LOGW("%s", msg.c_str());
}

}  // namespace

extern "C" {

// Loads libQnnTFLiteDelegate.so and resolves the plugin entry points.
// Idempotent. Returns 0 on success, negative on failure (see last_error).
__attribute__((visibility("default")))
int32_t vault_qnn_prepare(const char *native_lib_dir) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_create != nullptr) return 0;
    if (native_lib_dir == nullptr || native_lib_dir[0] == '\0') {
        set_error("native_lib_dir is empty");
        return -1;
    }
    g_native_dir = native_lib_dir;

    // FastRPC resolves DSP-side skels through ADSP_LIBRARY_PATH
    // (semicolon-separated). App dir first, then the standard vendor
    // locations so a vendor-provided skel still works if ours is missing.
    std::string adsp = g_native_dir +
        ";/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp";
    setenv("ADSP_LIBRARY_PATH", adsp.c_str(), 1);

    g_lib = dlopen("libQnnTFLiteDelegate.so", RTLD_NOW | RTLD_LOCAL);
    if (g_lib == nullptr) {
        const char *err = dlerror();
        set_error(std::string("dlopen libQnnTFLiteDelegate.so failed: ") +
                  (err ? err : "unknown"));
        return -2;
    }
    g_create = reinterpret_cast<CreateFn>(dlsym(g_lib, "tflite_plugin_create_delegate"));
    g_destroy = reinterpret_cast<DestroyFn>(dlsym(g_lib, "tflite_plugin_destroy_delegate"));
    if (g_create == nullptr || g_destroy == nullptr) {
        set_error("libQnnTFLiteDelegate.so lacks the external-delegate plugin ABI");
        dlclose(g_lib);
        g_lib = nullptr;
        g_create = nullptr;
        g_destroy = nullptr;
        return -3;
    }
    LOGI("QNN delegate library loaded from %s", g_native_dir.c_str());
    return 0;
}

// Creates an HTP delegate. Returns a TfLiteDelegate* or nullptr.
//   perf_mode: QnnDelegate HtpPerformanceMode (2 = burst, 3 = high perf, ...)
//   precision: 0 = quantized, 1 = FP16 (MiniLM is a float model -> 1)
//   log_level: 3 = INFO, required for the "N nodes delegated" report
//   cache_dir/model_token: optional; enable the compiled-graph cache so a
//   relaunch skips HTP graph preparation. Pass empty strings to disable.
__attribute__((visibility("default")))
void *vault_qnn_delegate_create(const char *skel_dir, int32_t perf_mode,
                                int32_t precision, int32_t log_level,
                                const char *cache_dir, const char *model_token) {
    CreateFn create;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        create = g_create;
    }
    if (create == nullptr) {
        set_error("vault_qnn_prepare() has not succeeded");
        return nullptr;
    }

    std::vector<std::string> keys = {
        "backend_type", "skel_library_dir", "htp_performance_mode",
        "htp_precision", "htp_pd_session", "log_level",
    };
    std::vector<std::string> values = {
        "htp",
        skel_dir != nullptr ? skel_dir : g_native_dir,
        std::to_string(perf_mode),
        std::to_string(precision),
        "0",  // unsigned PD
        std::to_string(log_level),
    };
    if (cache_dir != nullptr && cache_dir[0] != '\0' &&
        model_token != nullptr && model_token[0] != '\0') {
        keys.emplace_back("cache_dir");
        values.emplace_back(cache_dir);
        keys.emplace_back("model_token");
        values.emplace_back(model_token);
    }

    std::vector<char *> k, v;
    for (auto &s : keys) k.push_back(s.data());
    for (auto &s : values) v.push_back(s.data());

    void *delegate = create(k.data(), v.data(), keys.size());
    if (delegate == nullptr) {
        set_error("tflite_plugin_create_delegate returned null (no HTP device, "
                  "FastRPC unavailable, or skel not found)");
        return nullptr;
    }
    LOGI("QNN HTP delegate created (perf=%d precision=%d)", perf_mode, precision);
    return delegate;
}

__attribute__((visibility("default")))
void vault_qnn_delegate_destroy(void *delegate) {
    if (delegate == nullptr) return;
    DestroyFn destroy;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        destroy = g_destroy;
    }
    if (destroy != nullptr) destroy(delegate);
}

// Last error on the calling thread, or "" — valid until the next call.
__attribute__((visibility("default")))
const char *vault_qnn_last_error() {
    return t_last_error.c_str();
}

}  // extern "C"
