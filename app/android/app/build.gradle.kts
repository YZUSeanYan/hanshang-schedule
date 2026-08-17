import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名配置（key.properties 与 yzu-release.jks 已生成，注意备份、勿提交公开仓库）
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseSigningConfigured =
    listOf("keyAlias", "keyPassword", "storePassword", "storeFile")
        .all { !keystoreProperties.getProperty(it, "").isNullOrBlank() }
val releaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (releaseBuildRequested && !releaseSigningConfigured) {
    throw GradleException(
        "Release 签名未完整配置：请在 key.properties 中配置 keyAlias、keyPassword、storePassword、storeFile"
    )
}

android {
    namespace = "cn.yzu.schedule.yzu_schedule"
    // Android 16（API 36）实时通知（灵动岛）API 需要编译 SDK 36
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 要求启用 core library desugaring（Java 8+ API 兼容）
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "cn.yzu.schedule.yzu_schedule"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias", "")
            keyPassword = keystoreProperties.getProperty("keyPassword", "")
            storePassword = keystoreProperties.getProperty("storePassword", "")
            val storeFilePath = keystoreProperties.getProperty("storeFile", "")
            if (storeFilePath.isNotEmpty()) {
                storeFile = file(storeFilePath)
            }
        }
    }

    buildTypes {
        release {
            // 正式渠道只服务 64 位 ARM 手机。32 位 ARM 与 x86/x86_64
            // 已明确不再兼容，避免一个 APK 重复携带三套 Flutter/SQLite 原生库。
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
            // AAR 依赖携带的预编译 jniLibs（sqlite3/tnet 等）不受 ndk.abiFilters
            // 约束，显式排除 32 位 ARM 与 x86/x86_64，保证包内只有 arm64-v8a。
            packaging {
                jniLibs {
                    excludes += setOf(
                        "lib/armeabi-v7a/**",
                        "lib/x86/**",
                        "lib/x86_64/**",
                    )
                }
            }
            // R8 与资源收缩暂缓（低风险路线：先出 arm64-only 候选包）。
            // 历史上有 WorkDatabase_Impl 被裁剪导致冷启动崩溃的记录，R8 必须
            // 作为独立变量在真机全回归后再单独开启；届时恢复 proguardFiles
            // 引用（配套 app/proguard-rules.pro 已保留在源码树中）。
            isMinifyEnabled = false
            isShrinkResources = false
            // release 任务缺签名时在配置阶段直接失败，禁止误发 debug 签名安装包。
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
