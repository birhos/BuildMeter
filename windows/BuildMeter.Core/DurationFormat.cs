namespace BuildMeter.Core;

public static class DurationFormat
{
    /// <summary>"1 sa 23 dk", "4 dk 05 sn", "42 sn"</summary>
    public static string Long(double t)
    {
        int s = (int)Math.Max(0, Math.Round(t, MidpointRounding.AwayFromZero));
        int h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        if (h > 0) return $"{h} sa {m} dk";
        if (m > 0) return $"{m} dk {sec:00} sn";
        return $"{sec} sn";
    }

    /// <summary>Grafik etiketi için kısa biçim: "1s23d", "12dk", "42sn"</summary>
    public static string Compact(double t)
    {
        int s = (int)Math.Max(0, Math.Round(t, MidpointRounding.AwayFromZero));
        int h = s / 3600, m = s % 3600 / 60;
        if (h > 0) return $"{h}s{m:00}d";
        if (m > 0) return $"{m}dk";
        return $"{s}sn";
    }

    /// <summary>Canlı sayaç: "02:15", "1:02:15"</summary>
    public static string Clock(double t)
    {
        int s = (int)Math.Max(0, t);
        int h = s / 3600, m = s % 3600 / 60, sec = s % 60;
        return h > 0 ? $"{h}:{m:00}:{sec:00}" : $"{m:00}:{sec:00}";
    }
}
