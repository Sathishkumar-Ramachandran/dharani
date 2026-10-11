plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dharani.dharani_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dharani.dharani_mobile"
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

        ndk {
            // 64-bit ARM phones, plus x86_64 for emulators.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DDHARANI_BUILD_TESTS=OFF", "-DANDROID_STL=c++_static", "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON")
            }
        }
    }

    externalNativeBuild {
        cmake {
            // Builds the shared native core (core-native, beckn-protocol-layer, ffi-bridge) as libdharani_ffi.so.
            path = file("../../../CMakeLists.txt")
            version = "3.31.5"
        }
    }

    packaging {
        // The Hexagon loader needs the QNN libraries as real files on disk.
        jniLibs.useLegacyPackaging = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // ONNX Runtime with the Qualcomm QNN execution provider, and Qualcomm's public QNN (QAIRT) runtime
    // libraries (HTP backend, Hexagon v81 stub/skel). QAIRT 2.42 matches both this ONNX Runtime build and the downloaded v0.55 models.
    implementation("com.microsoft.onnxruntime:onnxruntime-android-qnn:1.29.0")
    implementation("com.qualcomm.qti:qnn-runtime:2.42.0")
}

flutter {
    source = "../.."
}
