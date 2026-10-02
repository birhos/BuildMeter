package com.birhos.buildmeter.rider

import java.io.File
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.Executors

// ~/.buildmeter/events.jsonl yazıcısı. Satır biçimi wrapper/events.go ve
// vscode-extension/lib/events.js ile aynıdır.

/** Olay dosyasına satır ekler. Satırlar sırayla, tek bir arka plan iş parçacığında yazılır. */
class EventWriter(
    private val dataDir: File = defaultDataDir(),
    private val executor: Executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "BuildMeter events").apply { isDaemon = true }
    },
) {
    val eventsFile: File get() = File(dataDir, "events.jsonl")

    fun write(fields: Map<String, Any?>) {
        val line = toJson(fields) + "\n"
        executor.execute {
            try {
                dataDir.mkdirs()
                // Tek bir append; paralel yazıcılarla (wrapper, MSBuild hook'u) satırlar karışmaz.
                eventsFile.appendText(line, Charsets.UTF_8)
            } catch (_: Exception) {
                // Kayıt yazılamaması IDE'yi etkilememeli.
            }
        }
    }

    companion object {
        fun defaultDataDir(): File =
            System.getenv("BUILDMETER_DATA_DIR")?.takeIf { it.isNotEmpty() }?.let(::File)
                ?: File(System.getProperty("user.home"), ".buildmeter")

        /** MSBuild hook'unun yazdığı makine adıyla aynı biçim (alan adı kısmı atılır). */
        val host: String by lazy {
            val name = System.getenv("COMPUTERNAME")?.takeIf { it.isNotEmpty() }
                ?: runCatching {
                    ProcessBuilder("hostname").redirectErrorStream(true).start().inputStream.bufferedReader().readText().trim()
                }.getOrDefault("")
            name.substringBefore('.')
        }

        fun now(): Double = System.currentTimeMillis() / 1000.0

        /** Yalnızca string, sayı, boolean ve null değerli düz nesneler. */
        fun toJson(fields: Map<String, Any?>): String = fields.entries.joinToString(",", "{", "}") { (k, v) ->
            "${quote(k)}:" + when (v) {
                null -> "null"
                is String -> quote(v)
                is Number, is Boolean -> v.toString()
                else -> quote(v.toString())
            }
        }

        private fun quote(s: String): String = buildString {
            append('"')
            for (c in s) when {
                c == '"' -> append("\\\"")
                c == '\\' -> append("\\\\")
                c == '\n' -> append("\\n")
                c == '\r' -> append("\\r")
                c == '\t' -> append("\\t")
                c < ' ' -> append("\\u%04x".format(c.code))
                else -> append(c)
            }
            append('"')
        }
    }
}

/** Bir oturumun start ve end satırlarını yazar; end yalnızca bir kez yazılır. */
class Recorder(
    private val writer: EventWriter,
    project: String,
    kind: String = "run",
    private val start: Double = EventWriter.now(),
) {
    private val base: Map<String, Any?> = linkedMapOf(
        "id" to UUID.randomUUID().toString().replace("-", ""),
        "source" to "rider",
        "tech" to "dotnet",
        "tool" to "rider",
        "kind" to kind,
        "project" to project,
        "device" to "",
        "host" to EventWriter.host,
    )

    @Volatile
    var ended = false
        private set

    fun start() {
        // IDE kapanırsa (çökme dahil) uygulama bu pid'e bakıp açık oturumu düşürür.
        writer.write(linkedMapOf<String, Any?>("event" to "start") + base + mapOf("ts" to start, "pid" to ProcessHandle.current().pid()))
    }

    @Synchronized
    fun end(status: String) {
        if (ended) return
        ended = true
        writer.write(linkedMapOf<String, Any?>("event" to "end") + base + mapOf("start" to start, "ts" to EventWriter.now(), "status" to status))
    }
}
