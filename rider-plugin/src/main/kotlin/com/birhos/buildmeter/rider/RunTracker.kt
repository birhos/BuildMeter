package com.birhos.buildmeter.rider

import com.intellij.execution.ExecutionListener
import com.intellij.execution.process.ProcessEvent
import com.intellij.execution.process.ProcessHandler
import com.intellij.execution.process.ProcessListener
import com.intellij.execution.runners.ExecutionEnvironment
import com.intellij.openapi.Disposable
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.service
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.Key
import com.jetbrains.rider.run.configurations.IProjectBasedRunConfiguration
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * .NET projelerinin Run/Debug ile çalıştırılmasından uygulamanın hazır olmasına kadar geçen
 * süreyi kaydeder ("çalıştır → hazır").
 *
 * - Başlangıç: Run'a basıldığı an (Rider'ın "Build Project" ön görevinden önce).
 * - Bitiş: web, worker ve Blazor projelerinde çıktıdaki hazır satırı
 *   (`Now listening on:`, `Application started.`); konsol uygulamalarında sürecin başlaması.
 *
 * Build'in kendisini MSBuild hook'u `source: rider` ile ayrıca kaydeder; plugin build kaydı yazmaz.
 */
@Service(Service.Level.PROJECT)
class RunTracker(@Suppress("unused") private val project: Project) : Disposable {
    private class Run(val recorder: Recorder, val hosted: Boolean)

    private val writer = EventWriter()
    private val runs = ConcurrentHashMap<ExecutionEnvironment, Run>()
    private val readySignals = ReadySignals.forProfile("dotnet-run")

    fun scheduled(env: ExecutionEnvironment) {
        if (!System.getenv("BUILDMETER_DISABLE").isNullOrEmpty()) return
        val config = env.runProfile as? IProjectBasedRunConfiguration ?: return
        val path = config.getProjectFilePath().takeIf { it.isNotEmpty() } ?: return
        val recorder = Recorder(writer, DotnetProject.name(path))
        runs[env] = Run(recorder, DotnetProject.isHosted(File(path)))
        recorder.start()
    }

    /** Ön görev (build) başarısız oldu ya da kullanıcı build sırasında durdurdu. */
    fun notStarted(env: ExecutionEnvironment) {
        runs.remove(env)?.recorder?.end("failed")
    }

    /** Süreç çıktı vermeden önce dinlemeye başlanır; ilk satırlar kaçmaz. */
    fun starting(env: ExecutionEnvironment, handler: ProcessHandler) {
        val run = runs[env] ?: return
        if (!run.hosted) return
        val scanner = LineScanner { line -> readySignals.any { it.containsMatchIn(line) } }
        handler.addProcessListener(object : ProcessListener {
            override fun onTextAvailable(event: ProcessEvent, outputType: Key<*>) {
                if (run.recorder.ended) return
                scanner.write(event.text)
                if (scanner.done) {
                    runs.remove(env)
                    run.recorder.end("success")
                }
            }
        }, this)
    }

    /** Konsol uygulaması süreç başladığı an hazırdır. */
    fun started(env: ExecutionEnvironment) {
        val run = runs[env] ?: return
        if (run.hosted) return
        runs.remove(env)
        run.recorder.end("success")
    }

    /** Uygulama hazır olmadan süreç bitti. */
    fun terminated(env: ExecutionEnvironment, handler: ProcessHandler, exitCode: Int) {
        val run = runs.remove(env) ?: return
        val stoppedByUser = handler.getUserData(ProcessHandler.TERMINATION_REQUESTED) == true
        run.recorder.end(if (stoppedByUser || exitCode == 0) "cancelled" else "failed")
    }

    /** Proje kapanırken süren oturumlar açık kalmasın. */
    override fun dispose() {
        runs.values.forEach { it.recorder.end("cancelled") }
        runs.clear()
    }
}

/** Projenin çalıştırma olaylarını [RunTracker]'a iletir (plugin.xml'de projectListeners). */
class RunListener(private val project: Project) : ExecutionListener {
    private val tracker get() = project.service<RunTracker>()

    override fun processStartScheduled(executorId: String, env: ExecutionEnvironment) = tracker.scheduled(env)

    override fun processNotStarted(executorId: String, env: ExecutionEnvironment) = tracker.notStarted(env)

    override fun processStarting(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler) =
        tracker.starting(env, handler)

    override fun processStarted(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler) =
        tracker.started(env)

    override fun processTerminated(executorId: String, env: ExecutionEnvironment, handler: ProcessHandler, exitCode: Int) =
        tracker.terminated(env, handler, exitCode)
}
