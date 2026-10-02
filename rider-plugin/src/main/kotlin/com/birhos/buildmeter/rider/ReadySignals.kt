package com.birhos.buildmeter.rider

import java.io.File

/**
 * wrapper/profiles.json'daki "hazır" ifadeleri. Derleme sırasında
 * `buildmeter/ready-signals.txt` kaynağına "<profil>\t<regex>" satırları olarak yazılır.
 */
object ReadySignals {
    private val byProfile: Map<String, List<Regex>> by lazy {
        val text = ReadySignals::class.java.getResourceAsStream("/buildmeter/ready-signals.txt")
            ?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        parse(text)
    }

    fun parse(text: String): Map<String, List<Regex>> = text.lineSequence()
        .mapNotNull { line -> line.split('\t', limit = 2).takeIf { it.size == 2 } }
        .groupBy({ it[0] }, { Regex(it[1]) })

    fun forProfile(id: String): List<Regex> = byProfile[id].orEmpty()
}

/**
 * Süreç çıktısını satırlara böler, renk kodlarını atar ve her satırı [onLine]'a verir.
 * wrapper/events.go ve vscode-extension/lib/scanner.js içindeki LineScanner ile aynı davranır.
 */
class LineScanner(private val onLine: (String) -> Boolean) {
    private val partial = StringBuilder()
    var done = false
        private set

    @Synchronized
    fun write(chunk: String) {
        if (done) return
        partial.append(chunk)
        while (true) {
            val i = partial.indexOfFirst { it == '\n' || it == '\r' }
            if (i < 0) break
            val line = partial.substring(0, i)
            partial.delete(0, i + 1)
            if (check(line)) return
        }
        if (partial.length > 64 * 1024) partial.delete(0, partial.length - 4096)
        // Bazı araçlar hazır satırını satır sonu olmadan basar.
        if (partial.isNotEmpty()) check(partial.toString())
    }

    private fun check(line: String): Boolean {
        if (onLine(line.replace(ANSI, ""))) {
            done = true
            partial.setLength(0)
        }
        return done
    }

    companion object {
        private val ANSI = Regex("""\u001b\[[0-9;?]*[ -/]*[@-~]|\u001b][^\u0007\u001b]*(\u0007|\u001b\\)|\u001b[()][A-Za-z0-9]""")
    }
}

/** .NET proje dosyası bilgisi. */
object DotnetProject {
    private val hostedSdk = Regex("""Microsoft\.NET\.Sdk\.(Web|Worker|BlazorWebAssembly|Razor)""")

    /**
     * Web, worker ve Blazor projeleri "hazır" satırı basar; konsol uygulamaları basmaz ve
     * süreç başladığı an hazır sayılır. Dosya okunamazsa barındırılan uygulama varsayılır.
     */
    fun isHosted(projectFile: File): Boolean =
        runCatching { hostedSdk.containsMatchIn(projectFile.readText()) }.getOrDefault(true)

    fun name(projectFilePath: String): String = File(projectFilePath).nameWithoutExtension
}
