namespace BuildMeter.Core;

/// <summary>Bir build, çalıştırma ya da debug oturumu. Zamanlar Unix saniyesidir.</summary>
public sealed class Session
{
    public string Id { get; set; } = "";
    public string Source { get; set; } = "other";
    public string Tech { get; set; } = "flutter";
    public string Tool { get; set; } = "";
    /// <summary>Aynı build'in parçalarını bağlayan id (solution build'indeki projeler, wrapper'ın kaydı).</summary>
    public string Group { get; set; } = "";
    /// <summary>Kaydı yazan makine; boşsa yerel makine.</summary>
    public string Host { get; set; } = "";
    /// <summary>MSBuild: çözüm dosyası, grupsuz kayıtları birleştirmek için.</summary>
    public string Solution { get; set; } = "";
    public string Kind { get; set; } = "run";
    public string Project { get; set; } = "?";
    public string Device { get; set; } = "";
    public string Status { get; set; } = "running";
    public double Start { get; set; }
    public double? End { get; set; }
    public int Pid { get; set; }

    public bool IsActive => End is null;
    public bool IsMSBuild => Tool == "msbuild";

    public double EndOr(double now) => End ?? now;

    public double Duration(double now) => EndOr(now) - Start;

    /// <summary>Raporlarda gösterilen makine adı.</summary>
    public string Machine => Host.Length > 0 ? Host : LocalHost;

    /// <summary>MSBuild hook'unun yazdığı <c>$([System.Environment]::MachineName)</c> ile aynıdır.</summary>
    public static string LocalHost { get; } = Environment.MachineName;

    /// <summary>Oturumun [start, end) penceresiyle kesişimi; kesişim yoksa <c>null</c>.</summary>
    public (double Start, double End)? Clipped(double start, double end, double now)
    {
        double a = Math.Max(Start, start), b = Math.Min(EndOr(now), end);
        return b > a ? (a, b) : null;
    }

    public Session Clone() => (Session)MemberwiseClone();
}
