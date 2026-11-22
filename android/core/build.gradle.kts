plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.sealctl.core"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests { isReturnDefaultValues = true; isIncludeAndroidResources = true } }
}

dependencies {
    // UniFFI bindings call the library through JNA (SPEC.md 5.3).
    api("net.java.dev.jna:jna:${libs.versions.jna.get()}@aar")
    api(libs.coroutines.android)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
