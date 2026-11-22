plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.sealctl.places"
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
    implementation(libs.core.ktx)
    api(libs.location)
    implementation(libs.coroutines.play)
    implementation(libs.coroutines.android)
}
