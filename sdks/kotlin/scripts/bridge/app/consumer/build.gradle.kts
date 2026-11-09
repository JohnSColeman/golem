plugins {
    kotlin("multiplatform")
    id("com.google.devtools.ksp")
    id("cloud.golem.wasm-component")
}

group = "cloud.golem.app"
version = "0.1.0-SNAPSHOT"

repositories {
    mavenLocal()
    mavenCentral()
}

// Pinned in gradle.properties (`golemKotlinVersion`); plugin versions are pinned in settings.gradle.kts.
val golemKotlinVersion = providers.gradleProperty("golemKotlinVersion").get()

kotlin {
    @OptIn(org.jetbrains.kotlin.gradle.ExperimentalWasmDsl::class)
    wasmWasi {
        binaries.executable()
        nodejs()
    }

    sourceSets {
        val wasmWasiMain by getting {
            // The clients `golem build` generates for the agent and tool dependencies of this component.
            for (client in listOf("calculator-guest-client", "arg-probe-tool-guest-client", "stream-probe-tool-guest-client", "git-probe-tool-guest-client")) {
                kotlin.srcDir("../golem-temp/bridge-sdk/kotlin/internal/$client/src/wasmWasiMain/kotlin")
            }
            dependencies {
                // The Golem Kotlin SDK is a NORMAL Kotlin/Wasm dependency -- it is compiled
                // directly into this agent's own wasm module. No JS, no bundling. Resolves from
                // mavenLocal.
                implementation("cloud.golem:golem-kotlin-sdk:$golemKotlinVersion")
            }
        }
    }
}

dependencies {
    // KSP processor: reads the @Agent classes and generates the real
    // @WasmExport("golem:agent/guest@2.0.0#...") functions + registration.
    add("kspWasmWasi", "cloud.golem:golem-kotlin-ksp:$golemKotlinVersion")
}

// `golem build` runs the plugin's `nativeComponent` task: Kotlin/Wasm compile -> wasm-tools
// component embed -> wasm-tools component new --adapt (WASI p1->p2) -> wasm-tools validate.
// No JS/QuickJS anywhere in this path.
wasmComponent {
    moduleName.set("bridge_consumer")
}
