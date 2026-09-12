// Minimal Android logcat macros for the llama.cpp JNI wrapper. Adapted from
// llama.cpp's own examples/llama.android/lib/src/main/cpp/logging.h (same
// upstream project this wrapper links against) with the tag changed to match
// this app's existing convention — LlmChannel.kt (the MediaPipe path) already
// logs under "vault-llm", so this is "vault-llama".
#pragma once

#include <android/log.h>
#include "ggml.h"

#ifndef LOG_TAG
#define LOG_TAG "vault-llama"
#endif

#ifndef LOG_MIN_LEVEL
#if defined(NDEBUG)
#define LOG_MIN_LEVEL ANDROID_LOG_INFO
#else
#define LOG_MIN_LEVEL ANDROID_LOG_VERBOSE
#endif
#endif

// __android_log_is_loggable needs API 30, which is newer than this app's
// minSdk — the LOG_MIN_LEVEL comparison below is the same filter it would
// have done, just resolved by these macros at compile time instead of by
// the OS at runtime. __android_log_print/_write still apply the platform's
// own priority filtering regardless, so nothing here loses filtering, only
// the (very small) cost of skipping a call outright below LOG_MIN_LEVEL.
static inline int vault_should_log(int prio) {
    return prio >= LOG_MIN_LEVEL;
}

#if LOG_MIN_LEVEL <= ANDROID_LOG_VERBOSE
#define LOGv(...) do { if (vault_should_log(ANDROID_LOG_VERBOSE)) __android_log_print(ANDROID_LOG_VERBOSE, LOG_TAG, __VA_ARGS__); } while (0)
#else
#define LOGv(...) ((void)0)
#endif

#if LOG_MIN_LEVEL <= ANDROID_LOG_DEBUG
#define LOGd(...) do { if (vault_should_log(ANDROID_LOG_DEBUG)) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__); } while (0)
#else
#define LOGd(...) ((void)0)
#endif

#define LOGi(...) do { if (vault_should_log(ANDROID_LOG_INFO )) __android_log_print(ANDROID_LOG_INFO , LOG_TAG, __VA_ARGS__); } while (0)
#define LOGw(...) do { if (vault_should_log(ANDROID_LOG_WARN )) __android_log_print(ANDROID_LOG_WARN , LOG_TAG, __VA_ARGS__); } while (0)
#define LOGe(...) do { if (vault_should_log(ANDROID_LOG_ERROR)) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__); } while (0)

static inline int vault_log_prio_from_ggml(enum ggml_log_level level) {
    switch (level) {
        case GGML_LOG_LEVEL_ERROR: return ANDROID_LOG_ERROR;
        case GGML_LOG_LEVEL_WARN:  return ANDROID_LOG_WARN;
        case GGML_LOG_LEVEL_INFO:  return ANDROID_LOG_INFO;
        case GGML_LOG_LEVEL_DEBUG: return ANDROID_LOG_DEBUG;
        default:                   return ANDROID_LOG_DEFAULT;
    }
}

static inline void vault_llama_android_log_callback(enum ggml_log_level level,
                                                      const char * text,
                                                      void * /*user*/) {
    const int prio = vault_log_prio_from_ggml(level);
    if (!vault_should_log(prio)) return;
    __android_log_write(prio, LOG_TAG, text);
}
