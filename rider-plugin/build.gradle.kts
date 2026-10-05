import groovy.json.JsonSlurper

plugins {
    id("org.jetbrains.kotlin.jvm") version "2.4.20"
    id("org.jetbrains.intellij.platform") version "2.19.0"
}

group = "com.birhos.buildmeter"
version = providers.gradleProperty("pluginVersion").get()

kotlin {
    jvmToolchain(21)
}

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        // Yerel Rider'a karşı derlemek indirmeyi önler: -PriderPath=/Applications/Rider.app
        val riderPath = providers.gradleProperty("riderPath")
        if (riderPath.isPresent) {
            local(riderPath)
        } else {
            rider(providers.gradleProperty("riderVersion")) { useInstaller = false }
        }
    }
    testImplementation("junit:junit:4.13.2")
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "261"
            untilBuild = provider { null }
        }
    }
    buildSearchableOptions = false
    pluginVerification {
        ides {
            val riderPath = providers.gradleProperty("riderPath")
            if (riderPath.isPresent) local(riderPath) else recommended()
        }
    }
}

// Hazır sinyalleri wrapper, editör eklentisi ve plugin için tek yerde tutulur:
// wrapper/profiles.json'daki "ready" ifadeleri "<profil>\t<regex>" satırları olarak pakete girer.
val readySignals by tasks.registering {
    val input = layout.projectDirectory.file("../wrapper/profiles.json")
    val output = layout.buildDirectory.dir("generated/ready-signals")
    inputs.file(input)
    outputs.dir(output)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val profiles = (JsonSlurper().parse(input.asFile) as Map<String, Any?>)["profiles"] as List<Map<String, Any?>>
        val lines = profiles.flatMap { p -> (p["ready"] as? List<*>).orEmpty().map { "${p["id"]}\t$it" } }
        val file = output.get().file("buildmeter/ready-signals.txt").asFile
        file.parentFile.mkdirs()
        file.writeText(lines.joinToString("\n", postfix = "\n"))
    }
}

sourceSets.main {
    resources.srcDir(readySignals)
}
