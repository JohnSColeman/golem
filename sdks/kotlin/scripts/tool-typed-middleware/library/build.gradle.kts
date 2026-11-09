plugins {
    kotlin("multiplatform") version "2.4.0"
    id("com.google.devtools.ksp") version "2.3.9"
    `maven-publish`
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
        nodejs()
    }

    sourceSets {
        val wasmWasiMain by getting {
            dependencies {
                api("cloud.golem:golem-kotlin-sdk:0.0.0-SNAPSHOT")
            }
        }
    }
}

dependencies {
    add("kspWasmWasi", "cloud.golem:golem-kotlin-ksp:0.0.0-SNAPSHOT")
}

publishing {
    repositories { mavenLocal() }
}
