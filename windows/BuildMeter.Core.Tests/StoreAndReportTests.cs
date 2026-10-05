using System.Text;
using BuildMeter.Core;
using Xunit;

namespace BuildMeter.Core.Tests;

public class StoreAndReportTests : IDisposable
{
    readonly string _dir = Path.Combine(Path.GetTempPath(), "buildmeter-tests-" + Guid.NewGuid().ToString("N"));

    public StoreAndReportTests() => Directory.CreateDirectory(_dir);

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    void Append(string file, string text) => File.AppendAllText(Path.Combine(_dir, file), text, new UTF8Encoding(false));

    [Fact]
    public void StoreReadsAppendedLinesAndWaitsForHalfWrittenLine()
    {
        var store = new EventStore(_dir);
        Append("events.jsonl", """{"event":"start","id":"a","source":"terminal","tech":"dotnet","project":"Api","ts":100}""" + "\n");
        Assert.True(store.Refresh(110));
        Assert.True(Assert.Single(store.Sessions).IsActive);

        // Satır sonu gelmeden yazılan yarım satır sonraki okumaya kalır.
        Append("events.jsonl", """{"event":"end","id":"a","start":100,"status":"suc""");
        Assert.False(store.Refresh(120));
        Assert.True(store.Sessions[0].IsActive);

        Append("events.jsonl", "cess\",\"ts\":130}\n");
        Assert.True(store.Refresh(140));
        var s = Assert.Single(store.Sessions);
        Assert.Equal("success", s.Status);
        Assert.Equal(30, s.Duration(140), 3);
    }

    [Fact]
    public void StoreReadsPerHostFilesAndRestartsWhenFileShrinks()
    {
        var store = new EventStore(_dir);
        Append("events.jsonl", """{"event":"end","id":"a","start":100,"status":"success","project":"app","ts":160}""" + "\n");
        Append("events-WIN-PC.jsonl", """{"event":"end","id":"b","start":200,"status":"failed","project":"Api","host":"WIN-PC","ts":230}""" + "\n");
        File.WriteAllText(Path.Combine(_dir, "notes.txt"), "events değil");
        store.Refresh(300);
        Assert.Equal(["Api", "app"], store.Sessions.Select(s => s.Project));

        File.WriteAllText(Path.Combine(_dir, "events.jsonl"), "");
        Assert.True(store.Refresh(300));
        Assert.Equal("Api", Assert.Single(store.Sessions).Project);
    }

    [Fact]
    public void StaleSessionsExpire()
    {
        var store = new EventStore(_dir);
        Append("events.jsonl", """{"event":"start","id":"old","project":"app","ts":100}""" + "\n");
        store.Refresh(200);
        store.ExpireDeadSessions(200);
        Assert.Single(store.Sessions);
        store.ExpireDeadSessions(100 + 3 * 3600 + 1);
        Assert.Empty(store.Sessions);
    }

    [Theory]
    [InlineData(0, "0 sn")]
    [InlineData(42.4, "42 sn")]
    [InlineData(245, "4 dk 05 sn")]
    [InlineData(4980, "1 sa 23 dk")]
    public void LongDuration(double seconds, string expected) => Assert.Equal(expected, DurationFormat.Long(seconds));

    [Theory]
    [InlineData(135, "02:15")]
    [InlineData(3735, "1:02:15")]
    public void ClockDuration(double seconds, string expected) => Assert.Equal(expected, DurationFormat.Clock(seconds));

    [Fact]
    public void WeekStartsOnMonday()
    {
        var (start, end) = ReportRange.Week.Interval(new DateTime(2026, 10, 4, 15, 0, 0, DateTimeKind.Local)); // Pazar
        Assert.Equal(new DateTime(2026, 9, 28), start);
        Assert.Equal(new DateTime(2026, 10, 5), end);
    }

    [Fact]
    public void ReportTextAndCsv()
    {
        var now = new DateTime(2026, 10, 2, 18, 0, 0, DateTimeKind.Local);
        double at(int h, int m) => Stats.Unix(new DateTime(2026, 10, 2, h, m, 0, DateTimeKind.Local));
        var sessions = new List<Session>
        {
            new() { Id = "1", Source = "rider", Tech = "dotnet", Tool = "msbuild", Kind = "build", Project = "Api", Device = "net8.0|Debug", Host = "WIN-PC", Start = at(9, 0), End = at(9, 2), Status = "success" },
            new() { Id = "2", Source = "terminal", Tech = "next", Tool = "npm", Kind = "dev", Project = "web; site", Host = "WIN-PC", Start = at(10, 0), End = at(10, 0) + 30, Status = "failed" },
        };

        var text = ReportBuilder.Text(sessions, ReportRange.Today, null, now);
        Assert.StartsWith("BuildMeter · Build Bekleme Raporu (Bugün)\n2 Ekim 2026, Cuma\n\n• Toplam bekleme süresi: 2 dk 30 sn", text);
        Assert.Contains("• Build sayısı: 2 (1 başarılı, 1 başarısız/iptal)", text);
        Assert.Contains("  - .NET: 2 dk 00 sn (1 build)", text);
        Assert.Contains("  - Rider: 2 dk 00 sn", text);
        Assert.DoesNotContain("Makineye göre", text);

        var csv = ReportBuilder.Csv(sessions, ReportRange.Today, now).Split('\n');
        Assert.Equal("﻿baslangic;bitis;sure_sn;sure;proje;teknoloji;arac;kaynak;tur;cihaz;durum;makine", csv[0]);
        Assert.Equal("2026-10-02 09:00:00;2026-10-02 09:02:00;120;2 dk 00 sn;Api;.NET;msbuild;Rider;build;net8.0|Debug;Başarılı;WIN-PC", csv[1]);
        Assert.Equal("2026-10-02 10:00:00;2026-10-02 10:00:30;30;30 sn;\"web; site\";Next.js;npm;Terminal;dev;;Başarısız;WIN-PC", csv[2]);

        Assert.Equal("dotnet-build-raporu-week-2026-10-02.csv", ReportBuilder.CsvFileName(ReportRange.Week, "dotnet", now));
    }

    [Fact]
    public void WeeklyReportHasDailyAndMachineBreakdown()
    {
        var now = new DateTime(2026, 10, 2, 18, 0, 0, DateTimeKind.Local);
        double at(int day, int h) => Stats.Unix(new DateTime(2026, 10, day, h, 0, 0, DateTimeKind.Local));
        var sessions = new List<Session>
        {
            new() { Id = "1", Project = "app", Host = "MAC", Start = at(1, 9), End = at(1, 9) + 60, Status = "success" },
            // Farklı makinelerde örtüşen build'ler bekleme süresinde tek sayılır.
            new() { Id = "2", Project = "Api", Host = "WIN-PC", Start = at(2, 9), End = at(2, 9) + 120, Status = "success" },
            new() { Id = "3", Project = "app", Host = "MAC", Start = at(2, 9) + 60, End = at(2, 9) + 180, Status = "success" },
        };

        var text = ReportBuilder.Text(sessions, ReportRange.Week, null, now);
        Assert.Contains("28 Eyl Pzt – 4 Eki Paz", text);
        Assert.Contains("• Toplam bekleme süresi: 4 dk 00 sn", text);
        Assert.Contains("Günlük dağılım:\n  - 1 Eki Per: 1 dk 00 sn\n  - 2 Eki Cum: 3 dk 00 sn", text);
        Assert.Contains("Makineye göre:\n  - MAC: 3 dk 00 sn\n  - WIN-PC: 2 dk 00 sn", text);
        Assert.Equal([0, 0, 0, 0, 0, 60, 180], Stats.DailyTotals(sessions, 7, now).Select(d => d.Total));
    }
}
