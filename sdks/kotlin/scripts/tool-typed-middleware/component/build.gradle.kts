plugins {
    kotlin("multiplatform") version "2.4.0"
    id("com.google.devtools.ksp") version "2.3.9"
    id("cloud.golem.wasm-component") version "0.0.0-SNAPSHOT"
}

group = "cloud.golem.fixtures"
version = "0.0.0-SNAPSHOT"

repositories {
    mavenLocal()
    mavenCentral()
}

kotlin {
    @OptIn(org.jetbrains.kotlin.gradle.ExperimentalWasmDsl::class)
    wasmWasi {
        binaries.executable()
        nodejs()
    }

    sourceSets {
        val wasmWasiMain by getting {
            dependencies {
                implementation("cloud.golem:golem-kotlin-sdk:0.0.0-SNAPSHOT")
                // The tool definitions live in this library; the component re-declares nothing.
                implementation("cloud.golem.fixtures:typed-tools:0.0.0-SNAPSHOT")
            }
        }
    }
}

dependencies {
    add("kspWasmWasi", "cloud.golem:golem-kotlin-ksp:0.0.0-SNAPSHOT")
}

wasmComponent {
    moduleName.set("typed-middleware")
    witNativeDir.set(file("../../../wit-native"))
}
