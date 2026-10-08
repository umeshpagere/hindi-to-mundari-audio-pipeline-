plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mundari.mundari_pipeline"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mundari.mundari_pipeline"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    androidResources {
        // Disable lint failures for release builds that may reference missing intermediate directories
        lint {
            abortOnError = false
            checkReleaseBuilds = false
        }
        // ML model and tokenizer files
        noCompress += "onnx"
        noCompress += "model"
        noCompress += "txt"
        noCompress += "wav"
        // espeak-ng-data files bundled for Piper-VITS TTS (must not be compressed)
        noCompress += "dict"        // *_dict language dictionaries
        noCompress += "phondata"    // phoneme data
        noCompress += "phonindex"   // phoneme index
        noCompress += "phontab"     // phoneme table
        noCompress += "intonations" // intonation data
        noCompress += "manifest"    // phondata-manifest
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            pickFirsts.add("lib/**/libonnxruntime.so")
            pickFirsts.add("lib/**/libc++_shared.so")
            pickFirsts.add("lib/**/libsherpa-onnx-c-api.so")
            pickFirsts.add("lib/**/libsherpa-onnx-cxx-api.so")
            pickFirsts.add("lib/**/libsherpa-onnx-jni.so")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
