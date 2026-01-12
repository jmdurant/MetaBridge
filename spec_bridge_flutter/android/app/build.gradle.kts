plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.specbridge.app"
    compileSdk = 36
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }

    defaultConfig {
        applicationId = "com.specbridge.app"
        minSdk = 26  // Required for Meta Wearables SDK
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Meta Wearables SDK
    // Requires GitHub token with read:packages scope
    implementation("com.meta.wearable:mwdat-core:0.3.0")
    implementation("com.meta.wearable:mwdat-camera:0.3.0")

    // Coroutines for Kotlin Flow
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Lifecycle for coroutine scope
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
}
