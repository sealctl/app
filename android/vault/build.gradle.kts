plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.sealctl.vault"
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
    api(project(":core"))
    implementation(libs.core.ktx)
    api(libs.biometric)
    implementation(libs.fragment)
    implementation(libs.blockstore)
    implementation(libs.coroutines.play)

    testImplementation(libs.junit)
    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
