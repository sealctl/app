import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Untracked build settings (android/local.properties):
//   sealctl.relayUrl      relay origin; production by default
//   sealctl.testDelaySecs debug builds only: shortens the level 3 delay for tests
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val relayUrl = localProps.getProperty("sealctl.relayUrl", "https://relay.sealctl.com")
val testDelaySecs = localProps.getProperty("sealctl.testDelaySecs", "0").toInt()

// The Firebase configuration is written at build time and never committed (SPEC.md 17.2).
// Without it the app builds and runs, with push turned off.
val hasFirebase = file("google-services.json").exists()
if (hasFirebase) apply(plugin = libs.plugins.google.services.get().pluginId)

android {
    namespace = "com.sealctl.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.sealctl.app"
        minSdk = 28
        targetSdk = 36
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "RELAY_URL", "\"$relayUrl\"")
        buildConfigField("boolean", "HAS_FIREBASE", "$hasFirebase")
        ndk { abiFilters += listOf("arm64-v8a", "x86_64", "armeabi-v7a") }
    }

    buildTypes {
        debug {
            buildConfigField("int", "TEST_DELAY_SECS", "$testDelaySecs")
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            buildConfigField("int", "TEST_DELAY_SECS", "0")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources.excludes += "META-INF/{AL2.0,LGPL2.1}"
        jniLibs.useLegacyPackaging = false
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }

    lint {
        abortOnError = true
        warningsAsErrors = false
        disable += listOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":vault"))
    implementation(project(":relay"))
    implementation(project(":places"))
    implementation(project(":notify"))
    implementation(project(":designsystem"))

    implementation(libs.core.ktx)
    implementation(libs.activity.compose)
    implementation(libs.fragment)
    implementation(libs.navigation.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.work.runtime)
    implementation(libs.coroutines.android)
    implementation(libs.coroutines.play)
    implementation(libs.camerax.camera2)
    implementation(libs.camerax.lifecycle)
    implementation(libs.camerax.view)
    implementation(libs.zxing.cpp)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.uiautomator)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
}
