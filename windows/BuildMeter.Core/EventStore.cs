using System.Diagnostics;

namespace BuildMeter.Core;

/// <summary>
/// Toplayıcıların (terminal wrapper'ı, editör eklentisi, MSBuild hook'u) yazdığı olay
/// dosyalarını izler ve oturumları üretir. Okunan dosyalar: <c>events.jsonl</c> ve makine
/// başına yazılan <c>events-&lt;host&gt;.jsonl</c>.
/// </summary>
public sealed class EventStore
{
    /// <summary>Bitişi gelmeyen ve süreci de bilinmeyen oturumlar bu süreden sonra yok sayılır.</summary>
    const double StaleAfter = 3 * 3600;

    sealed class Cursor
    {
        public long Offset;
        public byte[] PendingTail = [];
    }

    EventLog _log = new();
    Dictionary<string, Cursor> _cursors = new();

    public EventStore(string? dataDirectory = null)
    {
        DataDirectory = dataDirectory ?? DefaultDataDirectory();
    }

    public string DataDirectory { get; }

    /// <summary>Birleştirilmiş oturumlar, en yeni başta.</summary>
    public IReadOnlyList<Session> Sessions { get; private set; } = [];

    public IEnumerable<Session> Active => Sessions.Where(s => s.IsActive);

    /// <summary><c>BUILDMETER_DATA_DIR</c> ya da <c>%USERPROFILE%\.buildmeter</c>.</summary>
    public static string DefaultDataDirectory()
    {
        var custom = Environment.GetEnvironmentVariable("BUILDMETER_DATA_DIR");
        if (!string.IsNullOrEmpty(custom)) return custom;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".buildmeter");
    }

    public static bool IsEventsFile(string name) =>
        name.StartsWith("events", StringComparison.Ordinal) && name.EndsWith(".jsonl", StringComparison.Ordinal);

    /// <summary>
    /// Yeni satırları okur. Bir şey değiştiyse ya da <paramref name="force"/> verildiyse (süren
    /// oturumların süresi ve açık MSBuild kapanışı zamana bağlıdır) oturumları yeniden hesaplar.
    /// Yeni satır okunduysa true döner.
    /// </summary>
    public bool Refresh(double now, bool force = true)
    {
        bool changed = ReadNewEvents();
        if (changed || force) Publish(now);
        return changed;
    }

    public void ReloadAll(double now)
    {
        _log = new EventLog();
        _cursors = new Dictionary<string, Cursor>();
        Refresh(now);
    }

    /// <summary>
    /// Terminal kapatıldığında ya da editör çöktüğünde <c>end</c> gelmez. Süreci ölmüş veya çok
    /// eski aktif oturumları listeden çıkarır. MSBuild kayıtlarını <see cref="SessionMerger"/>
    /// başarısız olarak kapatır; başka makinenin süreçleri buradan denetlenemez.
    /// </summary>
    public void ExpireDeadSessions(double now)
    {
        var expired = _log.ById.Values
            .Where(s => s.IsActive && !s.IsMSBuild)
            .Where(s => now - s.Start > StaleAfter || (IsLocal(s) && s.Pid > 0 && !IsRunning(s.Pid)))
            .Select(s => s.Id)
            .ToList();
        foreach (var id in expired) _log.Remove(id);
        if (expired.Count > 0) Publish(now);
    }

    void Publish(double now) =>
        Sessions = SessionMerger.Merge(_log.ById.Values, now).OrderByDescending(s => s.Start).ToList();

    bool ReadNewEvents()
    {
        Dictionary<string, long> sizes;
        try
        {
            Directory.CreateDirectory(DataDirectory);
            sizes = new DirectoryInfo(DataDirectory).EnumerateFiles()
                .Where(f => IsEventsFile(f.Name))
                .ToDictionary(f => f.Name, f => f.Length);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }

        // Bir dosya kesildi, yeniden yazıldı ya da silindiyse her şeyi baştan oku.
        bool shrunk = _cursors.Any(c => sizes.GetValueOrDefault(c.Key) < c.Value.Offset);
        if (shrunk)
        {
            _log = new EventLog();
            _cursors = new Dictionary<string, Cursor>();
        }

        bool changed = shrunk;
        foreach (var (name, size) in sizes.OrderBy(p => p.Key, StringComparer.Ordinal))
            if (ReadFile(name, size)) changed = true;
        return changed;
    }

    bool ReadFile(string name, long size)
    {
        if (!_cursors.TryGetValue(name, out var cursor)) _cursors[name] = cursor = new Cursor();
        if (size <= cursor.Offset) return false;

        byte[] chunk;
        try
        {
            // Yazıcılar dosyayı açık tutarken de okunabilmesi için paylaşımlı açılır.
            using var stream = new FileStream(Path.Combine(DataDirectory, name), FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(cursor.Offset, SeekOrigin.Begin);
            using var buffer = new MemoryStream();
            stream.CopyTo(buffer);
            chunk = buffer.ToArray();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }

        cursor.Offset += chunk.Length;
        var data = cursor.PendingTail.Length == 0 ? chunk : [.. cursor.PendingTail, .. chunk];
        // Yarım yazılmış son satırı bir sonraki okumaya bırak.
        int lastNewline = Array.LastIndexOf(data, (byte)'\n');
        if (lastNewline < 0)
        {
            cursor.PendingTail = data;
            return false;
        }
        cursor.PendingTail = data[(lastNewline + 1)..];
        _log.Ingest(data[..lastNewline]);
        return true;
    }

    static bool IsLocal(Session s) =>
        s.Host.Length == 0 || string.Equals(s.Host, Session.LocalHost, StringComparison.OrdinalIgnoreCase);

    static bool IsRunning(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // Erişilemeyen süreç vardır ama sorgulanamaz; açık sayılır.
            return true;
        }
    }
}
