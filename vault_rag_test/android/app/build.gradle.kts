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
