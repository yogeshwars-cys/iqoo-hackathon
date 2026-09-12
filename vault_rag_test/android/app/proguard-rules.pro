# R8 rules for the MediaPipe LLM Inference runtime.
#
# Adding com.google.mediapipe:tasks-genai broke `flutter build apk --release`
# with:
#
#   ERROR: R8: Missing class com.google.auto.value.AutoValue$Builder
#   ERROR: R8: Missing class com.google.protobuf.Internal$ProtoMethodMayReturnNull
#   ... and several more in the same two packages
#
# Neither package is actually missing at runtime. AutoValue is a compile-time
# annotation processor whose annotations have CLASS retention, and the
# protobuf Internal$* types are javac-only markers on generated code. They are
# referenced by the AAR's bytecode but never loaded, so R8 is warning about
# code that cannot execute. -dontwarn is the correct response; adding the
# artifacts as real dependencies would ship two libraries to fix a warning.

-dontwarn com.google.auto.value.**
-dontwarn com.google.protobuf.**

# tasks-genai also references MediaPipe's image types for the multimodal
# entry points (LlmInferenceSession.addImage and friends):
#
#   ERROR: R8: Missing class com.google.mediapipe.framework.image.MPImage
#   ... plus the four extractor classes around it
#
# Those live in tasks-vision, which this app does not depend on because it
# only ever calls generateResponse with text. Pulling in a vision library to
# satisfy a reference on a code path we never take would add tens of
# megabytes to an APK that is already large. -dontwarn is the right trade:
# the classes are unreachable, so their absence cannot surface at runtime.
-dontwarn com.google.mediapipe.framework.image.**

# MediaPipe resolves much of its own graph by reflection and reaches Java
# objects from JNI, so R8 cannot see those references. Without this the
# release build strips classes the native layer then fails to find - and it
# fails at model-load time, not at build time, which is a far worse place to
# discover it.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.mediapipe.tasks.genai.** { *; }
-keepclassmembers class com.google.mediapipe.** {
    native <methods>;
}

# Generated protobuf message classes are instantiated reflectively by the
# runtime's own parser.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

# vault_llama_jni.cpp binds natives via JNI_OnLoad + RegisterNatives rather
# than the Java_pkg_Class_method naming convention (this package name has
# underscores, which that convention escapes as literal "_1" — easy to get
# wrong with nothing to catch it). RegisterNatives looks the class up by its
# fully-qualified name string and binds native methods by name+signature, so
# both the class name and its method names/signatures must survive R8
# unrenamed, or the lookup and the binding silently stop matching.
-keep class com.example.vault_rag_test.LlamaEngine { *; }
