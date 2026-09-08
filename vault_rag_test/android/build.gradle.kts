allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")

    // Flutter plugins pin their own Java source/target compatibility —
    // tflite_flutter 0.12.1 declares 11 — while their Kotlin tasks inherit the
    // JDK running Gradle (21 here). AGP 9 / Kotlin 2.x treat that mismatch as a
    // hard error:
    //   Inconsistent JVM-target compatibility detected for tasks
    //   'compileDebugJavaWithJavac' (11) and 'compileDebugKotlin' (21).
    // Normalise both sides to 17 — what :app already uses — for every module.
    //
    // configureEach is lazy, so this reaches tasks registered later too. It has
    // to be here rather than in an afterEvaluate block: evaluationDependsOn
    // above means some subprojects are already evaluated by this point, and
    // afterEvaluate throws once that has happened.
    // This has to go through AGP's `android { compileOptions { ... } }`
    // extension rather than JavaCompile.sourceCompatibility — the consistency
    // check reads the extension, so configuring the task alone leaves it still
    // reporting 11 — and it has to run *after* the plugin's own build.gradle
    // has set its 11, or that overwrites us.
    val normaliseJvmTarget = {
        extensions
            .findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileOptions {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
            .configureEach {
                compilerOptions.jvmTarget.set(
                    org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
                )
            }
        Unit
    }

    // evaluationDependsOn above means some subprojects are already evaluated by
    // now, and afterEvaluate throws once that has happened.
    if (state.executed) normaliseJvmTarget() else afterEvaluate { normaliseJvmTarget() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
