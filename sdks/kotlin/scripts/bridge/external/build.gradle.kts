plugins {
    kotlin("jvm")
    application
}

repositories {
    mavenCentral()
}

// The directory `golem-cli generate-bridge --language kotlin` wrote; run.sh passes it.
val bridgeClient = providers.gradleProperty("bridgeClient").get()

sourceSets.main {
    kotlin.srcDir("$bridgeClient/src/main/kotlin")
}

application {
    mainClass.set("ExternalMainKt")
}
