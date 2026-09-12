plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.vault_rag_test"
    // tflite_flutter 0.12.x declares compileSdk 36, and a library may not be
    // compiled against a newer SDK than its consumer, so this is pinned rather
    // than inherited from flutter.compileSdkVersion.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Builds llama.cpp (vendored as a pinned submodule under
    // src/main/cpp/third_party/llama.cpp) from source, once per ABI Gradle
    // targets. See src/main/cpp/CMakeLists.txt for why add_subdirectory
    // rather than a prebuilt .so.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.vault_rag_test"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The real target is the iQOO 15 (arm64-v8a) only. Building llama.cpp
        // a second and third time for armeabi-v7a/x86_64 — ABIs nothing here
        // is ever tested or shipped on — would roughly triple every native
        // build for no device this project runs on, and the OpenCL headers/
        // lib Stage 0 installed into the NDK sysroot only exist for
        // arm64-v8a, so an armeabi-v7a native build fails outright rather
        // than just wasting time. `clear()` first: abiFilters is a
        // MutableSet Flutter's plugin already populated with all three
        // ABIs, and `+=` alone only unions into that set rather than
        // replacing it. Drop this filter (Flutter's own engine libs follow
        // the same list) if an x86_64 emulator or armeabi-v7a device is
        // ever actually needed.
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    // NETWORK ISOLATION IS A BUILD PROPERTY, NOT A RUNTIME PROMISE.
    //
    //   airgap  (default)  the release APK requests zero network permissions.
    //                      src/main declares none, and src/airgapRelease
    //                      strips INTERNET / ACCESS_NETWORK_STATE even if a
    //                      plugin manifest tries to merge them in. The Dart
    //                      side reads appFlavor and hides the LAN bridge.
    //   lan                keeps INTERNET for the WebSocket bridge to
    //                      bridge_server.py (src/lan/AndroidManifest.xml).
    //
    // Debug/profile builds of either flavor still get INTERNET from
    // src/debug and src/profile — Flutter's tooling needs it to reach the
    // Dart VM service — which is why the removal lives in the
    // variant-specific airgapRelease source set rather than in airgap/.
    //
    // Verify after every release build:
    //   aapt2 dump permissions build/app/outputs/flutter-apk/app-airgap-release.apk
    flavorDimensions += "network"
    productFlavors {
        create("airgap") {
            dimension = "network"
            isDefault = true
        }
        create("lan") {
            dimension = "network"
            applicationIdSuffix = ".lan"
            versionNameSuffix = "-lan"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // MediaPipe's AAR references AutoValue and protobuf marker types
            // that exist only at compile time, which fails R8 with "Missing
            // class" errors, and it resolves classes reflectively from JNI,
            // which R8 cannot see and therefore strips. proguard-rules.pro
            // explains both in detail.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    // MediaPipe LLM Inference - the Gemma runtime. Brings its own prebuilt
    // native libraries for every ABI, which is most of why the APK is large.
    //
    // Pinned rather than floating: this artifact has changed its Kotlin API
    // between minor versions (setPreferredBackend was setUseGpu not long
    // ago), and a silent bump would break the build at a point far from the
    // change.
    implementation("com.google.mediapipe:tasks-genai:0.10.24")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
