using System.Text.Json;
using BuildMeter.Core;
using Xunit;

namespace BuildMeter.Core.Tests;

// spec/fixtures/ altındaki vakaları macOS uygulamasının (FixtureTests.swift) ve wrapper'ın
// (stats_test.go) testleriyle aynı şekilde doğrular.
public class FixtureTests
{
    static readonly string Root = FindFixtures();

    public static TheoryData<string> Cases()
    {
        var data = new TheoryData<string>();
        foreach (var dir in Directory.GetDirectories(Root).Order(StringComparer.Ordinal))
            // output/ gibi expected.json'u olmayan klasörler vaka değildir.
            if (File.Exists(Path.Combine(dir, "expected.json"))) data.Add(Path.GetFileName(dir));
        return data;
    }

    [Fact]
    public void FixturesExist() => Assert.NotEmpty(Cases());

    [Theory]
    [MemberData(nameof(Cases))]
    public void Fixture(string name)
    {
        var dir = Path.Combine(Root, name);
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(dir, "expected.json")));
        var root = doc.RootElement;
        double now = root.GetProperty("now").GetDouble();
        double start = root.GetProperty("window").GetProperty("start").GetDouble();
        double end = root.GetProperty("window").GetProperty("end").GetDouble();
        var want = root.GetProperty("summary");

        var log = new EventLog();
        foreach (var file in Directory.GetFiles(dir).Select(Path.GetFileName).Where(f => EventStore.IsEventsFile(f!)).Order(StringComparer.Ordinal))
            log.Ingest(File.ReadAllBytes(Path.Combine(dir, file!)));
        var sessions = SessionMerger.Merge(log.ById.Values, now);
        var got = Stats.Summarize(sessions, start, end, now);

        var listed = sessions.Where(s => s.Start >= start && s.Start <= end)
            .OrderBy(s => s.Start).ThenBy(s => s.Source, StringComparer.Ordinal).ToList();
        var expected = want.GetProperty("sessions").EnumerateArray().ToList();
        Assert.True(listed.Count == expected.Count, $"{name}: oturum sayısı {listed.Count}, beklenen {expected.Count}");
        for (int i = 0; i < listed.Count; i++)
        {
            var (g, e) = (listed[i], expected[i]);
            var label = $"{name}: oturum {i}";
            Assert.Equal(e.GetProperty("project").GetString(), g.Project);
            Assert.Equal(e.GetProperty("tech").GetString(), g.Tech);
            Assert.Equal(e.GetProperty("source").GetString(), g.Source);
            Assert.Equal(e.GetProperty("kind").GetString(), g.Kind);
            Assert.Equal(e.GetProperty("status").GetString(), g.Status);
            AssertNear(e.GetProperty("start").GetDouble(), g.Start, label + " start");
            var wantEnd = e.GetProperty("end");
            if (wantEnd.ValueKind == JsonValueKind.Null) Assert.Null(g.End);
            else AssertNear(wantEnd.GetDouble(), g.End ?? double.NaN, label + " end");
        }

        Assert.Equal(want.GetProperty("count").GetInt32(), got.Count);
        Assert.Equal(want.GetProperty("successCount").GetInt32(), got.SuccessCount);
        AssertNear(want.GetProperty("mergedTotal").GetDouble(), got.MergedTotal, name + " mergedTotal");
        AssertNear(want.GetProperty("sumTotal").GetDouble(), got.SumTotal, name + " sumTotal");
        AssertMap(want.GetProperty("byTech"), got.ByTech, name + " byTech");
        AssertMap(want.GetProperty("bySource"), got.BySource, name + " bySource");
        AssertMap(want.GetProperty("byProject"), got.ByProject, name + " byProject");

        var byHost = new Dictionary<string, double>();
        foreach (var s in got.Sessions.Where(s => s.Host.Length > 0))
            if (s.Clipped(start, end, now) is { } iv)
                byHost[s.Host] = byHost.GetValueOrDefault(s.Host) + iv.End - iv.Start;
        AssertMap(want.GetProperty("byHost"), byHost.ToList(), name + " byHost");
    }

    static void AssertNear(double expected, double actual, string label) =>
        Assert.True(Math.Abs(expected - actual) < 0.001, $"{label}: {actual}, beklenen {expected}");

    static void AssertMap(JsonElement expected, IEnumerable<KeyValuePair<string, double>> actual, string label)
    {
        var want = expected.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetDouble());
        var got = actual.ToDictionary(p => p.Key, p => p.Value);
        Assert.True(want.Keys.Order().SequenceEqual(got.Keys.Order()),
            $"{label} anahtarları [{string.Join(", ", got.Keys)}], beklenen [{string.Join(", ", want.Keys)}]");
        foreach (var (key, value) in want) AssertNear(value, got[key], $"{label}[{key}]");
    }

    static string FindFixtures()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "spec", "fixtures");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("spec/fixtures bulunamadı");
    }
}
