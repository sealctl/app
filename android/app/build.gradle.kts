import java.util.Properties
import java.util.zip.ZipInputStream
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

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
            isShrinkResources = true
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
        // The Apache-2.0 and LGPL-2.1 texts kotlinx ships here: the Licences screen shows the
        // Apache-2.0 text and every library's NOTICE file (androidNotices below) instead.
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

// Third-party notices (SPEC.md 11.19), shown in Settings → About → Licences: every Android
// library in the release build, from its Maven POM (name, version, licence), the NOTICE files the
// libraries ship, the Apache-2.0 text, and the Rust crates (../notices/rust-crates.txt, made by
// scripts/notices.sh with cargo-about). No plugin: the POMs resolve like any other artifact.
abstract class AndroidNotices : DefaultTask() {
    @get:InputFiles @get:PathSensitive(PathSensitivity.NAME_ONLY) abstract val poms: ConfigurableFileCollection
    /** Parent POMs, where a library inherits its licence. */
    @get:InputFiles @get:PathSensitive(PathSensitivity.NAME_ONLY) abstract val parentPoms: ConfigurableFileCollection
    @get:InputFiles @get:PathSensitive(PathSensitivity.NAME_ONLY) abstract val libraries: ConfigurableFileCollection
    @get:InputDirectory @get:PathSensitive(PathSensitivity.RELATIVE) abstract val shared: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun write() {
        fun Element.child(name: String): Element? =
            (0 until childNodes.length).map { childNodes.item(it) }.filterIsInstance<Element>().firstOrNull { it.tagName == name }
        fun Element.text(name: String): String = child(name)?.textContent?.trim().orEmpty()
        val factory = DocumentBuilderFactory.newInstance().apply {
            setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
        }
        fun coords(p: Element): String {
            val parent = p.child("parent")
            val group = p.text("groupId").ifEmpty { parent?.text("groupId").orEmpty() }
            val version = p.text("version").ifEmpty { parent?.text("version").orEmpty() }
            return "$group:${p.text("artifactId")}:$version"
        }
        val parents = parentPoms.files.map { factory.newDocumentBuilder().parse(it).documentElement }.associateBy { coords(it) }
        fun licencesOf(p: Element?): List<String> {
            if (p == null) return emptyList()
            val own = p.child("licenses")?.getElementsByTagName("license")?.let { list ->
                (0 until list.length).map { list.item(it) as Element }.map { l ->
                    listOf(l.text("name"), l.text("url")).filter { it.isNotEmpty() }.joinToString(", ")
                }
            }.orEmpty()
            if (own.isNotEmpty()) return own
            val parent = p.child("parent") ?: return emptyList()
            return licencesOf(parents["${parent.text("groupId")}:${parent.text("artifactId")}:${parent.text("version")}"])
        }
        val entries = poms.files.map { pom ->
            val project = factory.newDocumentBuilder().parse(pom).documentElement
            val name = project.text("name").ifEmpty { project.text("artifactId") }
            val licences = licencesOf(project)
            val home = project.text("url")
            buildString {
                append("$name\n  ${coords(project)}\n")
                if (licences.isEmpty()) append("  Licence: see ${home.ifEmpty { "its project page" }}\n")
                licences.forEach { append("  Licence: $it\n") }
            }
        }.sorted()
        // NOTICE files, and licence files other than the Apache-2.0 text (shown once below)
        val notices = sortedMapOf<String, String>()
        for (lib in libraries.files.filter { it.isFile && (it.name.endsWith(".jar") || it.name.endsWith(".aar")) }) {
            fun scan(zip: ZipInputStream) {
                generateSequence { zip.nextEntry }.forEach { e ->
                    val n = e.name.substringAfterLast('/')
                    when {
                        e.name.endsWith("classes.jar") -> scan(ZipInputStream(zip))
                        n.startsWith("NOTICE") || n.startsWith("LICENSE") -> {
                            val text = zip.readBytes().decodeToString().trim()
                            val apache = text.take(300).contains("Apache License") && n.startsWith("LICENSE")
                            if (!apache && text.isNotEmpty() && text !in notices.values) notices[lib.name + " " + e.name] = text
                        }
                    }
                }
            }
            lib.inputStream().use { scan(ZipInputStream(it)) }
        }
        val dir = outputDir.get().asFile.resolve("notices").apply { mkdirs() }
        dir.resolve("android-libraries.txt").writeText(buildString {
            append("Android libraries in the sealctl app\n\n")
            append("The Android app is built with the libraries below, each under the licence its publisher states. ")
            append("JNA is offered under LGPL-2.1-or-later or Apache-2.0; we use it under Apache-2.0. ")
            append("Google Play services and Firebase are under the Android Software Development Kit License.\n\n")
            entries.forEach { append(it).append("\n") }
            notices.forEach { (where, text) -> append("=== From $where\n\n$text\n\n") }
            append("=== Protocol Buffers (in androidx.datastore:datastore-preferences-external-protobuf), BSD-3-Clause\n\n")
            append(shared.file("protobuf-BSD-3-Clause.txt").get().asFile.readText().trim()).append("\n\n")
            append("=== Apache License 2.0\n\n")
            append(shared.file("Apache-2.0.txt").get().asFile.readText())
        })
        shared.file("rust-crates.txt").get().asFile.copyTo(dir.resolve("rust-crates.txt"), overwrite = true)
    }
}

val androidNotices = tasks.register<AndroidNotices>("androidNotices") {
    shared.set(rootProject.layout.projectDirectory.dir("../notices"))
}

androidComponents {
    // The release build's libraries, for every variant's notices.
    onVariants(selector().withBuildType("release")) { variant ->
        val rc = variant.runtimeConfiguration
        val artifactType = Attribute.of("artifactType", String::class.java)
        androidNotices.configure {
            for (type in listOf("aar", "jar")) {
                libraries.from(rc.incoming.artifactView { attributes { attribute(artifactType, type) }; lenient(true) }.files)
            }
            fun pomsOf(coords: Collection<String>) =
                configurations.detachedConfiguration(*coords.map { dependencies.create("$it@pom") }.toTypedArray())
                    .apply { isTransitive = false }.files
            val modulePoms = provider {
                pomsOf(rc.incoming.resolutionResult.allComponents.mapNotNull { it.id as? org.gradle.api.artifacts.component.ModuleComponentIdentifier }
                    .map { "${it.group}:${it.module}:${it.version}" })
            }
            poms.from(modulePoms)
            // Parent POMs, followed up the chain.
            parentPoms.from(modulePoms.map { start ->
                val seen = mutableSetOf<String>()
                val found = mutableSetOf<File>()
                var files: Set<File> = start
                while (files.isNotEmpty()) {
                    val next = files.mapNotNull { f ->
                        Regex("(?s)<parent>.*?<groupId>(.*?)</groupId>.*?<artifactId>(.*?)</artifactId>.*?<version>(.*?)</version>.*?</parent>")
                            .find(f.readText())?.destructured?.let { (g, a, v) -> "${g.trim()}:${a.trim()}:${v.trim()}" }
                    }.filter { seen.add(it) }
                    // one at a time: in one configuration, two versions of a parent would resolve to one
                    files = next.flatMap { pomsOf(listOf(it)) }.toSet()
                    found += files
                }
                found
            })
        }
    }
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(androidNotices, AndroidNotices::outputDir)
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
