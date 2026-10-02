namespace BuildMeter.Core;

public enum ReportRange { Today, Yesterday, Week, Last7, Month, LastMonth }

public static class ReportRanges
{
    public static readonly ReportRange[] All = Enum.GetValues<ReportRange>();

    public static string Title(this ReportRange r) => r switch
    {
        ReportRange.Today => "Bugün",
        ReportRange.Yesterday => "Dün",
        ReportRange.Week => "Bu hafta",
        ReportRange.Last7 => "Son 7 gün",
        ReportRange.Month => "Bu ay",
        _ => "Geçen ay",
    };

    /// <summary><c>buildmeter report --range</c> ile aynı adlar; CSV dosya adında kullanılır.</summary>
    public static string Key(this ReportRange r) => r switch
    {
        ReportRange.Today => "today",
        ReportRange.Yesterday => "yesterday",
        ReportRange.Week => "week",
        ReportRange.Last7 => "last7",
        ReportRange.Month => "month",
        _ => "lastmonth",
    };

    public static bool IsSingleDay(this ReportRange r) => r is ReportRange.Today or ReportRange.Yesterday;

    /// <summary>Aralığı yerel saatle hesaplar; haftalar pazartesi başlar. Sonuç [start, end) yerel saattir.</summary>
    public static (DateTime Start, DateTime End) Interval(this ReportRange r, DateTime now)
    {
        var today = now.Date;
        switch (r)
        {
            case ReportRange.Yesterday:
                return (today.AddDays(-1), today);
            case ReportRange.Week:
                var start = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
                return (start, start.AddDays(7));
            case ReportRange.Last7:
                return (today.AddDays(-6), today.AddDays(1));
            case ReportRange.Month:
                var month = new DateTime(today.Year, today.Month, 1);
                return (month, month.AddMonths(1));
            case ReportRange.LastMonth:
                var last = new DateTime(today.Year, today.Month, 1).AddMonths(-1);
                return (last, last.AddMonths(1));
            default:
                return (today, today.AddDays(1));
        }
    }
}

public sealed record Summary(
    List<Session> Sessions,
    double MergedTotal,
    double SumTotal,
    int Count,
    int SuccessCount,
    double Longest,
    double Average,
    List<KeyValuePair<string, double>> ByTech,
    List<KeyValuePair<string, double>> BySource,
    List<KeyValuePair<string, double>> ByProject);

public static class Stats
{
    /// <summary>Yerel <see cref="DateTime"/>'ı Unix saniyesine çevirir.</summary>
    public static double Unix(DateTime local) =>
        new DateTimeOffset(DateTime.SpecifyKind(local, DateTimeKind.Local)).ToUnixTimeMilliseconds() / 1000.0;

    public static DateTime FromUnix(double ts) =>
        DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(ts * 1000)).LocalDateTime;

    public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    /// <summary>Pencereyle kesişen oturumların özeti. <paramref name="includeActive"/> false ise süren oturumlar sayılmaz.</summary>
    public static Summary Summarize(IEnumerable<Session> sessions, double start, double end, double now, bool includeActive = true)
    {
        var relevant = new List<Session>();
        var intervals = new List<(double, double)>();
        var byTech = new Dictionary<string, double>();
        var bySource = new Dictionary<string, double>();
        var byProject = new Dictionary<string, double>();
        var durations = new List<double>();
        double sum = 0;
        int success = 0;

        foreach (var s in sessions)
        {
            if (!includeActive && s.IsActive) continue;
            if (s.Clipped(start, end, now) is not { } iv) continue;
            relevant.Add(s);
            intervals.Add(iv);
            double d = iv.End - iv.Start;
            sum += d;
            Add(byTech, s.Tech, d);
            Add(bySource, s.Source, d);
            Add(byProject, s.Project, d);
            if (s.Status == "success") success++;
            if (!s.IsActive) durations.Add(s.End!.Value - s.Start);
        }

        return new Summary(
            relevant,
            MergedDuration(intervals),
            sum,
            relevant.Count,
            success,
            durations.Count > 0 ? durations.Max() : 0,
            durations.Count > 0 ? durations.Average() : 0,
            Sorted(byTech), Sorted(bySource), Sorted(byProject));
    }

    public static Summary Summarize(IEnumerable<Session> sessions, ReportRange range, DateTime now, bool includeActive = true)
    {
        var (start, end) = range.Interval(now);
        return Summarize(sessions, Unix(start), Unix(end), Unix(now), includeActive);
    }

    /// <summary>Son <paramref name="days"/> günün (bugün dahil) birleştirilmiş günlük toplamları, eskiden yeniye.</summary>
    public static List<(DateTime Day, double Total)> DailyTotals(IEnumerable<Session> sessions, int days, DateTime now, bool includeActive = true)
    {
        var list = sessions.Where(s => includeActive || !s.IsActive).ToList();
        var today = now.Date;
        var result = new List<(DateTime, double)>();
        for (int offset = days - 1; offset >= 0; offset--)
        {
            var day = today.AddDays(-offset);
            result.Add((day, DayTotal(list, day, Unix(now))));
        }
        return result;
    }

    /// <summary>[start, end) içindeki, bugünden sonraya geçmeyen günlerin toplamları (rapordaki günlük dağılım).</summary>
    public static List<(DateTime Day, double Total)> DailyBreakdown(IEnumerable<Session> sessions, DateTime start, DateTime end, DateTime now)
    {
        var list = sessions.ToList();
        var result = new List<(DateTime, double)>();
        for (var day = start; day < end && day <= now; day = day.AddDays(1))
            result.Add((day, DayTotal(list, day, Unix(now))));
        return result;
    }

    static double DayTotal(List<Session> sessions, DateTime day, double now)
    {
        double a = Unix(day), b = Unix(day.AddDays(1));
        return MergedDuration(Clipped(sessions, a, b, now));
    }

    /// <summary>Oturumların pencereyle kesişen aralıkları.</summary>
    public static IEnumerable<(double Start, double End)> Clipped(IEnumerable<Session> sessions, double start, double end, double now)
    {
        foreach (var s in sessions)
            if (s.Clipped(start, end, now) is { } iv) yield return iv;
    }

    /// <summary>Örtüşen aralıkları birleştirip toplam süreyi döndürür.</summary>
    public static double MergedDuration(IEnumerable<(double Start, double End)> intervals)
    {
        double total = 0;
        (double Start, double End)? current = null;
        foreach (var iv in intervals.OrderBy(i => i.Start))
        {
            if (current is { } c && iv.Start <= c.End)
            {
                current = (c.Start, Math.Max(c.End, iv.End));
                continue;
            }
            if (current is { } done) total += done.End - done.Start;
            current = iv;
        }
        if (current is { } last) total += last.End - last.Start;
        return total;
    }

    static void Add(Dictionary<string, double> map, string key, double value) =>
        map[key] = map.GetValueOrDefault(key) + value;

    static List<KeyValuePair<string, double>> Sorted(Dictionary<string, double> map) =>
        map.OrderByDescending(p => p.Value).ThenBy(p => p.Key, StringComparer.Ordinal).ToList();
}
