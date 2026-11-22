plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.sealctl.relay"
    compileSdk = 37
    defaultConfig {
        minSdk = 28
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions {
        unitTests {
            isReturnDefaultValues = true
            all { it.systemProperty("jna.library.path", rootProject.file("../target/debug").absolutePath) }
        }
    }
}

dependencies {
    api(project(":core"))
    api(libs.okhttp)
    api(libs.kotlinx.serialization.json)
    implementation(libs.coroutines.android)

    // JVM tests load the host build of libsealctl_app (cargo build -p sealctl-app) through JNA.
    testImplementation("net.java.dev.jna:jna:${libs.versions.jna.get()}")
    testImplementation(libs.junit)
    testImplementation(libs.mockwebserver)
    testImplementation(libs.coroutines.test)
}
