using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BuildMeter.Core;

// Bu dosya macOS uygulamasındaki EventLog.swift ve wrapper'daki stats.go ile aynı kuralları
// uygular. Üçü de spec/fixtures/ altındaki vakalarla doğrulanır; mantık değişirse hepsi
// birlikte değişmelidir.

/// <summary><c>~/.buildmeter/events*.jsonl</c> satırlarının biçimi.</summary>
public sealed class RawEvent
{
    [JsonPropertyName("event")] public string? Event { get; set; }
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("ts")] public double? Ts { get; set; }
    [JsonPropertyName("source")] public string? Source { get; set; }
    [JsonPropertyName("tech")] public string? Tech { get; set; }
    [JsonPropertyName("tool")] public string? Tool { get; set; }
    [JsonPropertyName("group")] public string? Group { get; set; }
    [JsonPropertyName("host")] public string? Host { get; set; }
    [JsonPropertyName("solution")] public string? Solution { get; set; }
    [JsonPropertyName("kind")] public string? Kind { get; set; }
    [JsonPropertyName("project")] public string? Project { get; set; }
    [JsonPropertyName("device")] public string? Device { get; set; }
    [JsonPropertyName("start")] public double? Start { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("pid")] public int? Pid { get; set; }
}

/// <summary>Olay satırlarından ham oturumları üretir. Dosyadan ve zamanlayıcıdan bağımsızdır.</summary>
public sealed class EventLog
{
    public Dictionary<string, Session> ById { get; } = new();

    /// <summary>Tam satırlardan oluşan metni uygular; bozuk satırlar atlanır.</summary>
    public void Ingest(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            RawEvent? e;
            try { e = JsonSerializer.Deserialize<RawEvent>(line); }
            catch (JsonException) { continue; }
            if (e?.Event is null || e.Id is null || e.Ts is null) continue;
            Apply(e);
        }
    }

    public void Ingest(byte[] data) => Ingest(Encoding.UTF8.GetString(data));

    public void Remove(string id) => ById.Remove(id);

    void Apply(RawEvent e)
    {
        string id = e.Id!;
        double ts = e.Ts!.Value;
        switch (e.Event)
        {
            case "start":
                // Aynı id başka bir dosyada ya da tekrar okunduysa biten oturumu geri açma.
                if (ById.TryGetValue(id, out var existing) && existing.End is not null) return;
                ById[id] = SessionFrom(e, ts);
                break;
            case "end":
                if (!ById.TryGetValue(id, out var s)) s = SessionFrom(e, e.Start ?? ts);
                if (e.Start is { } start) s.Start = start;
                if (!string.IsNullOrEmpty(e.Device)) s.Device = e.Device;
                if (!string.IsNullOrEmpty(e.Project)) s.Project = e.Project;
                if (!string.IsNullOrEmpty(e.Group)) s.Group = e.Group;
                s.Pid = 0;
                s.End = Math.Max(ts, s.Start);
                s.Status = e.Status is "success" or "failed" or "cancelled" ? e.Status : "failed";
                ById[id] = s;
                break;
            case "discard":
                ById.Remove(id);
                break;
        }
    }

    static Session SessionFrom(RawEvent e, double start) => new()
    {
        Id = e.Id!,
        Source = Titles.KnownSources.Contains(e.Source) ? e.Source! : "other",
        Tech = string.IsNullOrEmpty(e.Tech) ? "flutter" : Titles.KnownTechs.Contains(e.Tech) ? e.Tech : "other",
        Tool = e.Tool ?? "",
        Group = e.Group ?? "",
        Host = e.Host ?? "",
        Solution = e.Solution ?? "",
        Kind = string.IsNullOrEmpty(e.Kind) ? "run" : e.Kind,
        Project = string.IsNullOrEmpty(e.Project) ? "?" : e.Project,
        Device = e.Device ?? "",
        Start = start,
        Status = "running",
        Pid = e.Pid ?? 0,
    };
}
