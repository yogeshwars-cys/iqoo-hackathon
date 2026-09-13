cmake_minimum_required(VERSION 3.22.1)

project("vault_llama" LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --------------------------------------------------------------------------
# llama.cpp, vendored as a pinned git submodule under third_party/.
#
# Built from source via add_subdirectory rather than linking a prebuilt .so:
# Gradle's externalNativeBuild already invokes CMake once per target ABI, so
# letting it drive llama.cpp's own build means one build step produces
# correctly-linked libraries for whatever ABIs this app ships, instead of a
# second, separately-versioned prebuild step to keep in sync by hand.
#
# LLAMA_STANDALONE is OFF here (llama.cpp is a subdirectory of this project,
# not the top-level CMakeLists), which turns LLAMA_BUILD_COMMON off by
# default too — forced back ON below because the JNI wrapper needs
# common_sampler_*/common_tokenize/common_batch_* from libllama-common.
# --------------------------------------------------------------------------

set(LLAMA_SRC ${CMAKE_CURRENT_LIST_DIR}/third_party/llama.cpp)

set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)

# OpenCL only for arm64-v8a: Stage 0 installed the OpenCL headers and
# libOpenCL.so into the NDK sysroot's arm64-v8a lib directory only (that is
# the only ABI a real device here ever runs), so GGML_OPENCL=ON on any other
# ABI fails at CMake's find_package step rather than just being pointless.
# app/build.gradle.kts restricts the whole app to arm64-v8a for the same
# reason — this is a second, independent guard in case that ever changes
# without this file being revisited too.
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(GGML_OPENCL ON CACHE BOOL "" FORCE)
else()
    set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
endif()
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)

# Hexagon NPU support is opt-in via -DVAULT_GGML_HEXAGON=ON at configure time
# (Stage 0's toolchain build, not this one — the Hexagon SDK/headers only
# exist inside the snapdragon-toolchain Docker image, unavailable here). When
# it *is* available, GGML_HEXAGON and the two HEXAGON_*_ROOT variables get
# forwarded the same way GGML_OPENCL is above.
option(VAULT_GGML_HEXAGON "Build the Hexagon HTP backend (needs the Qualcomm Hexagon SDK)" OFF)
if(VAULT_GGML_HEXAGON)
    set(GGML_HEXAGON ON CACHE BOOL "" FORCE)
endif()

add_subdirectory(${LLAMA_SRC} llama-build)

add_library(vault_llama SHARED vault_llama_jni.cpp)

target_include_directories(vault_llama PRIVATE
    ${LLAMA_SRC}
    ${LLAMA_SRC}/common
    ${LLAMA_SRC}/include
    ${LLAMA_SRC}/ggml/include
)

target_link_libraries(vault_llama PRIVATE
    llama
    llama-common
    android
    log
)

# ---------------------------------------------------------------------------
# vault_qnn_delegate: thin C shim that dlopen()s Qualcomm's QNN LiteRT
# delegate (Maven AAR, not linked here) and returns a TfLiteDelegate* to Dart
# FFI for the MiniLM encoder. No Qualcomm headers or SDK at build time —
# see vault_qnn_delegate.cpp for why the plugin ABI is used. Independent of
# llama.cpp: GGML_HEXAGON stays OFF, the NPU is for embeddings only.
# ---------------------------------------------------------------------------
add_library(vault_qnn_delegate SHARED vault_qnn_delegate.cpp)
set_target_properties(vault_qnn_delegate PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_link_libraries(vault_qnn_delegate PRIVATE log dl)
# Keep the statically linked libc++ private: only the four vault_qnn_* entry
# points are exported, so nothing in this shim can interpose on symbols of
# the QNN, LiteRT or llama.cpp libraries sharing the process.
target_link_options(vault_qnn_delegate PRIVATE "-Wl,--exclude-libs,ALL")
