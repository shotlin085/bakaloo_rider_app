plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.grolin.rider"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (uses java.time APIs
        // that need core-library desugaring on minSdk < 26).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.grolin.rider"
        // Geolocator + flutter_secure_storage require API 23+.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Three flavors. All point at the same live backend (https://grolin.shotlin.in).
    // They differ only in app id suffix, app name, and a BuildConfig flag the
    // Dart side can read via --dart-define=FLAVOR=...
    flavorDimensions += "env"
    productFlavors {
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Bakaloo Rider Dev")
        }
        create("staging") {
            dimension = "env"
            applicationIdSuffix = ".staging"
            versionNameSuffix = "-staging"
            resValue("string", "app_name", "Bakaloo Rider Staging")
        }
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "Bakaloo Rider")
        }
    }

    buildTypes {
        release {
            // Debug-signed for now so `flutter run --release` works during development.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring runtime, required by
    // flutter_local_notifications. Version pinned per the package's
    // android docs (>= 2.1.4 for AGP 8 + JDK 17).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
