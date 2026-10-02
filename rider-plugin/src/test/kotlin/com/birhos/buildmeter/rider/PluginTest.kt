package com.birhos.buildmeter.rider

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class PluginTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun readySignalsComeFromProfilesJson() {
        val signals = ReadySignals.forProfile("dotnet-run")
        assertTrue(signals.isNotEmpty())
        assertTrue(signals.any { it.containsMatchIn("      Now listening on: http://localhost:5000") })
        assertTrue(signals.any { it.containsMatchIn("info: Microsoft.Hosting.Lifetime[0] Application started. Press Ctrl+C to shut down.") })
        assertFalse(signals.any { it.containsMatchIn("info: Microsoft.Hosting.Lifetime[0]") })
    }

    @Test
    fun readySignalsMatchRealAspNetCoreOutput() {
        // Wrapper ve editör eklentisinin de doğruladığı gerçek çıktı (spec/fixtures/output/).
        val output = File("../spec/fixtures/output/dotnet-run/aspnetcore-8.0.txt").readText()
        val signals = ReadySignals.forProfile("dotnet-run")
        val scanner = LineScanner { line -> signals.any { it.containsMatchIn(line) } }
        output.chunked(7).forEach(scanner::write)
        assertTrue(scanner.done)
    }

    @Test
    fun lineScannerStripsColorsAndHandlesPartialLines() {
        val seen = mutableListOf<String>()
        val scanner = LineScanner { line -> seen += line; line.contains("Now listening on:") }
        scanner.write("\u001b[32minfo\u001b[39m: starting\r\n      Now list")
        assertFalse(scanner.done)
        scanner.write("ening on: http://localhost:5000\n")
        assertTrue(scanner.done)
        assertEquals("info: starting", seen.first())
        scanner.write("later line\n")
        assertFalse(seen.contains("later line"))
    }

    @Test
    fun hostedProjectsAreDetectedFromSdk() {
        val web = temp.newFile("Api.csproj").apply { writeText("""<Project Sdk="Microsoft.NET.Sdk.Web"></Project>""") }
        val worker = temp.newFile("Jobs.csproj").apply { writeText("""<Project Sdk="Microsoft.NET.Sdk.Worker"></Project>""") }
        val console = temp.newFile("Tool.csproj").apply { writeText("""<Project Sdk="Microsoft.NET.Sdk"></Project>""") }
        assertTrue(DotnetProject.isHosted(web))
        assertTrue(DotnetProject.isHosted(worker))
        assertFalse(DotnetProject.isHosted(console))
        assertTrue(DotnetProject.isHosted(File(temp.root, "missing.csproj")))
        assertEquals("Api", DotnetProject.name(web.path))
    }

    @Test
    fun recorderWritesStartAndOneEnd() {
        val dir = temp.newFolder("data")
        val writer = EventWriter(dir) { it.run() }
        val recorder = Recorder(writer, "Shop \"Api\"", start = 100.5)
        recorder.start()
        recorder.end("success")
        recorder.end("failed")

        val lines = writer.eventsFile.readLines()
        assertEquals(2, lines.size)
        assertTrue(lines[0].startsWith("""{"event":"start","id":""""))
        assertTrue(lines[0].contains(""""source":"rider","tech":"dotnet","tool":"rider","kind":"run","project":"Shop \"Api\"""""))
        assertTrue(lines[0].contains(""""ts":100.5,"pid":"""))
        assertTrue(lines[1].contains(""""start":100.5"""))
        assertTrue(lines[1].endsWith(""""status":"success"}"""))
        val id = Regex(""""id":"([0-9a-f]{32})"""")
        assertEquals(id.find(lines[0])!!.groupValues[1], id.find(lines[1])!!.groupValues[1])
    }

    @Test
    fun jsonEscapesControlCharacters() {
        assertEquals("""{"a":"x\\y\n\u0001","b":1.5,"c":null,"d":true}""",
            EventWriter.toJson(linkedMapOf("a" to "x\\y\n\u0001", "b" to 1.5, "c" to null, "d" to true)))
    }
}
