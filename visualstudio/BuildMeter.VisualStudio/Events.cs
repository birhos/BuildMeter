using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace BuildMeter.VisualStudio;

// ~/.buildmeter/events.jsonl yazıcısı. Satır biçimi wrapper/events.go ve
// vscode-extension/lib/events.js ile aynıdır.

static class EventWriter
{
    static readonly object Gate = new();
    static Task _tail = Task.CompletedTask;

    public static string DataDirectory
    {
        get
        {
            var custom = Environment.GetEnvironmentVariable("BUILDMETER_DATA_DIR");
            return string.IsNullOrEmpty(custom)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".buildmeter")
                : custom!;
        }
    }

    public static double Now() => (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;

    /// <summary>Satırları sırayla, arayüz iş parçacığını bekletmeden ekler.</summary>
    public static void Write(IEnumerable<KeyValuePair<string, object?>> fields)
    {
        var line = ToJson(fields) + "\n";
        lock (Gate)
        {
            _tail = _tail.ContinueWith(_ =>
            {
                try
                {
                    Directory.CreateDirectory(DataDirectory);
                    // Tek bir append; paralel yazıcılarla (MSBuild hook'u, wrapper) satırlar karışmaz.
                    using var stream = new FileStream(Path.Combine(DataDirectory, "events.jsonl"), FileMode.Append,
                        FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                    var bytes = new UTF8Encoding(false).GetBytes(line);
                    stream.Write(bytes, 0, bytes.Length);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // Kayıt yazılamaması Visual Studio'yu etkilememeli.
                }
            }, TaskScheduler.Default);
        }
    }

    static string ToJson(IEnumerable<KeyValuePair<string, object?>> fields) =>
        "{" + string.Join(",", fields.Select(f => Quote(f.Key) + ":" + Value(f.Value))) + "}";

    static string Value(object? v) => v switch
    {
        null => "null",
        string s => Quote(s),
        double d => d.ToString("R", System.Globalization.CultureInfo.InvariantCulture),
        int i => i.ToString(System.Globalization.CultureInfo.InvariantCulture),
        _ => Quote(v.ToString()),
    };

    static string Quote(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < ' ') sb.AppendFormat("\\u{0:x4}", (int)c);
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}

/// <summary>Bir oturumun start ve end satırlarını yazar; end yalnızca bir kez yazılır.</summary>
sealed class Recorder
{
    readonly List<KeyValuePair<string, object?>> _base;
    readonly double _start;
    bool _started;

    public Recorder(string kind, string project, string? group = null, double? start = null)
    {
        _start = start ?? EventWriter.Now();
        _base =
        [
            new("id", Guid.NewGuid().ToString("N")),
            new("source", "visualstudio"),
            new("tech", "dotnet"),
            new("tool", "visualstudio"),
            new("kind", kind),
            new("project", project),
            new("device", ""),
            new("host", Environment.MachineName),
        ];
        if (!string.IsNullOrEmpty(group)) _base.Add(new("group", group));
    }

    public bool Ended { get; private set; }

    public void Start()
    {
        if (_started || Ended) return;
        _started = true;
        // Visual Studio kapanırsa (çökme dahil) uygulama bu pid'e bakıp açık oturumu düşürür.
        EventWriter.Write(Fields("start", new("ts", _start), new("pid", Process.GetCurrentProcess().Id)));
    }

    public void End(string status)
    {
        if (Ended) return;
        Start();
        Ended = true;
        EventWriter.Write(Fields("end", new("start", _start), new("ts", EventWriter.Now()), new("status", status)));
    }

    IEnumerable<KeyValuePair<string, object?>> Fields(string evt, params KeyValuePair<string, object?>[] extra) =>
        new[] { new KeyValuePair<string, object?>("event", evt) }.Concat(_base).Concat(extra);
}

/// <summary>wrapper/profiles.json'daki "hazır" ifadeleri (pakete gömülü).</summary>
static class ReadySignals
{
    static readonly Lazy<Dictionary<string, Regex[]>> ByProfile = new(Load);

    public static Regex[] For(string profile) => ByProfile.Value.TryGetValue(profile, out var r) ? r : [];

    static Dictionary<string, Regex[]> Load()
    {
        var result = new Dictionary<string, Regex[]>();
        using var stream = typeof(ReadySignals).Assembly.GetManifestResourceStream("profiles.json");
        if (stream is null) return result;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var root = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd());
        foreach (Dictionary<string, object> p in (object[])root["profiles"])
            if (p.TryGetValue("ready", out var ready) && ready is object[] patterns)
                result[(string)p["id"]] = patterns.Select(x => new Regex((string)x)).ToArray();
        return result;
    }
}

/// <summary>Çıktıyı satırlara böler, renk kodlarını atar (wrapper'daki LineScanner ile aynı).</summary>
sealed class LineScanner(Func<string, bool> onLine)
{
    static readonly Regex Ansi = new(@"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][A-Za-z0-9]");
    readonly StringBuilder _partial = new();

    public bool Done { get; private set; }

    public void Write(string chunk)
    {
        if (Done) return;
        _partial.Append(chunk);
        while (true)
        {
            var text = _partial.ToString();
            int i = text.IndexOfAny(['\n', '\r']);
            if (i < 0) break;
            _partial.Remove(0, i + 1);
            if (Check(text.Substring(0, i))) return;
        }
        if (_partial.Length > 64 * 1024) _partial.Remove(0, _partial.Length - 4096);
        if (_partial.Length > 0) Check(_partial.ToString());
    }

    bool Check(string line)
    {
        if (onLine(Ansi.Replace(line, "")))
        {
            Done = true;
            _partial.Clear();
        }
        return Done;
    }
}

static class DotnetProject
{
    static readonly Regex HostedSdk = new(@"Microsoft\.NET\.Sdk\.(Web|Worker|BlazorWebAssembly|Razor)");

    /// <summary>
    /// Web, worker ve Blazor projeleri "hazır" satırı basar; konsol uygulamaları basmaz ve
    /// süreç başladığı an hazır sayılır. Dosya okunamazsa barındırılan uygulama varsayılır.
    /// </summary>
    public static bool IsHosted(string? projectFile)
    {
        if (string.IsNullOrEmpty(projectFile)) return true;
        try { return HostedSdk.IsMatch(File.ReadAllText(projectFile)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return true; }
    }
}
