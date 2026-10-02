using System.Globalization;
using System.Text;

namespace BuildMeter.Core;

/// <summary>
/// Yönetime iletilecek metin ve CSV raporları. Biçim macOS uygulamasının "Raporu kopyala" ve
/// "CSV" çıktılarıyla (ReportBuilder.swift) ve <c>buildmeter report</c> komutuyla aynıdır.
/// </summary>
public static class ReportBuilder
{
    static readonly string[] MonthsLong = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"];
    static readonly string[] MonthsShort = ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"];
    static readonly string[] DaysLong = ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"];
    static readonly string[] DaysShort = ["Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"];

    /// <param name="tech">Yalnızca bu teknolojiye süzülmüş oturumlar için başlıkta gösterilir; <c>null</c> tümü.</param>
    public static string Text(IReadOnlyList<Session> sessions, ReportRange range, string? tech, DateTime now)
    {
        var (start, end) = range.Interval(now);
        double a = Stats.Unix(start), b = Stats.Unix(end), n = Stats.Unix(now);
        var s = Stats.Summarize(sessions, a, b, n);

        var lines = new List<string>();
        var scope = tech is null ? "" : Titles.Tech(tech) + " ";
        lines.Add($"BuildMeter · {scope}Build Bekleme Raporu ({range.Title()})");
        lines.Add(range.IsSingleDay() ? LongDay(start) : $"{ShortDay(start)} – {ShortDay(end.AddSeconds(-1))}");
        lines.Add("");
        lines.Add("• Toplam bekleme süresi: " + DurationFormat.Long(s.MergedTotal));
        if (s.SumTotal - s.MergedTotal > 60)
            lines.Add($"  (eşzamanlı build'ler tek sayıldı; düz toplam {DurationFormat.Long(s.SumTotal)})");

        int running = s.Sessions.Count(x => x.IsActive);
        int failed = s.Count - s.SuccessCount - running;
        var parts = new List<string> { $"{s.SuccessCount} başarılı" };
        if (failed > 0) parts.Add($"{failed} başarısız/iptal");
        if (running > 0) parts.Add($"{running} devam ediyor");
        lines.Add($"• Build sayısı: {s.Count} ({string.Join(", ", parts)})");
        if (s.Count > 0)
        {
            lines.Add("• Ortalama build süresi: " + DurationFormat.Long(s.Average));
            lines.Add("• En uzun build: " + DurationFormat.Long(s.Longest));
        }

        if (!range.IsSingleDay())
        {
            var days = Stats.DailyBreakdown(sessions, start, end, now).Where(d => d.Total > 0).ToList();
            if (days.Count > 0)
            {
                lines.Add("• Build yapılan gün başına ortalama: " + DurationFormat.Long(s.MergedTotal / days.Count));
                lines.Add("");
                lines.Add("Günlük dağılım:");
                foreach (var d in days) lines.Add($"  - {ShortDay(d.Day)}: {DurationFormat.Long(d.Total)}");
            }
        }

        if (tech is null && s.ByTech.Count > 0)
        {
            lines.Add("");
            lines.Add("Teknolojiye göre:");
            foreach (var (key, value) in s.ByTech)
                lines.Add($"  - {Titles.Tech(key)}: {DurationFormat.Long(value)} ({s.Sessions.Count(x => x.Tech == key)} build)");
        }

        var machines = s.Sessions.Select(x => x.Machine).Distinct().OrderBy(m => m, StringComparer.Ordinal).ToList();
        if (machines.Count > 1)
        {
            lines.Add("");
            lines.Add("Makineye göre:");
            foreach (var m in machines)
            {
                var total = Stats.MergedDuration(Stats.Clipped(s.Sessions.Where(x => x.Machine == m), a, b, n));
                lines.Add($"  - {m}: {DurationFormat.Long(total)}");
            }
        }

        if (s.BySource.Count > 0)
        {
            lines.Add("");
            lines.Add("Kaynağa göre:");
            foreach (var (key, value) in s.BySource) lines.Add($"  - {Titles.Source(key)}: {DurationFormat.Long(value)}");
        }

        if (s.ByProject.Count > 0)
        {
            lines.Add("");
            lines.Add("Projeye göre:");
            foreach (var (key, value) in s.ByProject)
                lines.Add($"  - {key}: {DurationFormat.Long(value)} ({s.Sessions.Count(x => x.Project == key)} build)");
        }
        return string.Join("\n", lines);
    }

    /// <summary>Excel Türkçe yerel ayarı için UTF-8 BOM ve noktalı virgülle ayrılmış CSV.</summary>
    public static string Csv(IReadOnlyList<Session> sessions, ReportRange range, DateTime now)
    {
        var (start, end) = range.Interval(now);
        double n = Stats.Unix(now);
        var s = Stats.Summarize(sessions, Stats.Unix(start), Stats.Unix(end), n);

        var sb = new StringBuilder("﻿baslangic;bitis;sure_sn;sure;proje;teknoloji;arac;kaynak;tur;cihaz;durum;makine\n");
        foreach (var x in s.Sessions.OrderBy(x => x.Start))
        {
            double d = x.Duration(n);
            string[] row =
            [
                CsvTime(x.Start), x.End is { } e ? CsvTime(e) : "",
                ((long)Math.Round(d, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture),
                DurationFormat.Long(d), x.Project, Titles.Tech(x.Tech), x.Tool, Titles.Source(x.Source), x.Kind,
                x.Device, Titles.Status(x.Status), x.Machine,
            ];
            sb.Append(string.Join(";", row.Select(Escape))).Append('\n');
        }
        return sb.ToString();
    }

    /// <summary>macOS uygulamasının önerdiği dosya adı: <c>[tech-]build-raporu-&lt;aralık&gt;-yyyy-MM-dd.csv</c>.</summary>
    public static string CsvFileName(ReportRange range, string? tech, DateTime now) =>
        $"{(tech is null ? "" : tech + "-")}build-raporu-{range.Key()}-{now:yyyy-MM-dd}.csv";

    /// <summary>"2 Ekim 2026, Cuma"</summary>
    public static string LongDay(DateTime d) => $"{d.Day} {MonthsLong[d.Month - 1]} {d.Year}, {DaysLong[(int)d.DayOfWeek]}";

    /// <summary>"2 Eki Cum"</summary>
    public static string ShortDay(DateTime d) => $"{d.Day} {MonthsShort[d.Month - 1]} {DaysShort[(int)d.DayOfWeek]}";

    /// <summary>Grafik ekseni için gün kısaltması: "Pzt".</summary>
    public static string Weekday(DateTime d) => DaysShort[(int)d.DayOfWeek];

    static string CsvTime(double ts) => Stats.FromUnix(ts).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    static string Escape(string v) =>
        v.IndexOfAny([';', '"', '\n']) < 0 ? v : "\"" + v.Replace("\"", "\"\"") + "\"";
}
