import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI 可以指定临时配置文件。本机优先读取 android/key.properties，再读取用户目录中的配置。
val releaseSigningFile = providers.environmentVariable("EASY_MUSIC_ANDROID_KEY_PROPERTIES").orNull
    ?.let { rootProject.file(it) }
    ?: rootProject.file("key.properties").takeIf { it.isFile }
    ?: File(System.getProperty("user.home"), ".local/share/easy-music/signing/key.properties")
val releaseSigningProperties = Properties().apply {
    if (releaseSigningFile.isFile) {
        releaseSigningFile.inputStream().use { load(it) }
    }
}
val missingReleaseSigningFields = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .filter { releaseSigningProperties.getProperty(it).isNullOrBlank() }
    .joinToString()

dependencies {
    implementation("androidx.media:media:1.7.0")
}

android {
    namespace = "dev.easymusic.easy_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.easymusic.easy_music"
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

        // 原生视频插件提供多套库，APK 只保留与 Flutter 引擎目标架构对应的库。
        val targetAbis = providers.gradleProperty("target-platform").orNull
            ?.split(",")
            ?.mapNotNull { platform ->
                when (platform) {
                    "android-arm" -> "armeabi-v7a"
                    "android-arm64" -> "arm64-v8a"
                    "android-x64" -> "x86_64"
                    else -> null
                }
            }
        if (!targetAbis.isNullOrEmpty() &&
            !providers.gradleProperty("split-per-abi").orNull.toBoolean() &&
            !providers.gradleProperty("disable-abi-filtering").orNull.toBoolean()
        ) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(targetAbis)
            }
        }
    }

    signingConfigs {
        create("release") {
            storeFile = releaseSigningProperties.getProperty("storeFile")
                ?.let { releaseSigningFile.parentFile.resolve(it) }
            storePassword = releaseSigningProperties.getProperty("storePassword")
            keyAlias = releaseSigningProperties.getProperty("keyAlias")
            keyPassword = releaseSigningProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// 只拦截发布构建，避免配置不完整时生成未签名产物。Debug 仍可正常构建。
val checkReleaseSigningProperties = tasks.register("checkReleaseSigningProperties") {
    doLast {
        if (missingReleaseSigningFields.isNotEmpty()) {
            throw GradleException(
                "Android Release signing is missing: $missingReleaseSigningFields. " +
                    "Configure android/key.properties or set EASY_MUSIC_ANDROID_KEY_PROPERTIES."
            )
        }
    }
}
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(checkReleaseSigningProperties)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
