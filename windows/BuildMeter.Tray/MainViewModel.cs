using System.ComponentModel;
using BuildMeter.Core;

namespace BuildMeter.Tray;

public sealed record ActiveItem(string Project, string Detail, string Clock);
public sealed record Chip(string Title, string Value);
public sealed record DayBar(string Weekday, string Value, double BarHeight, bool IsToday, string ToolTip);
public sealed record ProjectRow(string Name, string Value, double FillWidth);
public sealed record RecentRow(string StatusGlyph, string Status, string Project, string Kind, bool ShowKind, string Time, string Duration, string Detail);
public sealed record TechOption(string? Key, string Title);
public sealed record RangeOption(ReportRange Range, string Title);

/// <summary>Açılır pencerenin gösterdiği veriler (macOS menü bar penceresiyle aynı bölümler).</summary>
public sealed class MainViewModel : INotifyPropertyChanged
{
    const double ChartHeight = 72;
    const double ProjectBarWidth = 348;

    readonly EventStore _store;
    TechOption _techFilter = AllTechs;

    static readonly TechOption AllTechs = new(null, "Tümü");

    public MainViewModel(EventStore store) => _store = store;

    public event PropertyChangedEventHandler? PropertyChanged;

    public IReadOnlyList<ActiveItem> Active { get; private set; } = [];
    public bool HasActive => Active.Count > 0;

    public string TodayTotal { get; private set; } = "0 sn";
    public string Count { get; private set; } = "0";
    public string SuccessCount { get; private set; } = "0";
    public string Average { get; private set; } = "–";
    public string Longest { get; private set; } = "–";

    public IReadOnlyList<Chip> TechChips { get; private set; } = [];
    public bool ShowTechChips { get; private set; }
    public IReadOnlyList<Chip> SourceChips { get; private set; } = [];
    public IReadOnlyList<DayBar> Week { get; private set; } = [];
    public IReadOnlyList<ProjectRow> Projects { get; private set; } = [];
    public bool HasProjects => Projects.Count > 0;
    public IReadOnlyList<RecentRow> Recent { get; private set; } = [];
    public bool HasNoRecent => Recent.Count == 0;

    /// <summary>Kayıtlarda görülen teknolojiler; birden fazlaysa filtre gösterilir.</summary>
    public IReadOnlyList<TechOption> TechOptions { get; private set; } = [AllTechs];
    public bool ShowTechFilter { get; private set; }

    public TechOption TechFilter
    {
        get => _techFilter;
        set
        {
            if (value is null || value == _techFilter) return;
            _techFilter = value;
            Update(Stats.Now());
        }
    }

    public IReadOnlyList<RangeOption> RangeOptions { get; } =
        ReportRanges.All.Select(r => new RangeOption(r, r.Title())).ToList();

    /// <summary>"Raporu kopyala" ve "CSV" için seçili aralık.</summary>
    public RangeOption SelectedRange { get; set; } = new(ReportRange.Today, ReportRange.Today.Title());

    /// <summary>Teknoloji filtresi uygulanmış oturumlar.</summary>
    public IReadOnlyList<Session> FilteredSessions =>
        _techFilter.Key is { } tech ? _store.Sessions.Where(s => s.Tech == tech).ToList() : _store.Sessions;

    public string? FilterKey => _techFilter.Key;

    public void Update(double nowTs)
    {
        var now = Stats.FromUnix(nowTs);
        var sessions = FilteredSessions;

        var seen = _store.Sessions.Select(s => s.Tech).ToHashSet();
        var techs = Titles.KnownTechs.Append("other").Where(seen.Contains).ToList();
        if (_techFilter.Key is { } key && !techs.Contains(key)) techs.Add(key);
        // Liste değişmediyse aynı kalır; açık ComboBox her saniye yenilenip kapanmasın.
        if (!TechOptions.Skip(1).Select(o => o.Key).SequenceEqual(techs))
            TechOptions = [AllTechs, .. techs.Select(t => new TechOption(t, Titles.Tech(t)))];
        ShowTechFilter = techs.Count > 1 || _techFilter.Key is not null;

        Active = sessions.Where(s => s.IsActive).Select(s => new ActiveItem(
            s.Project,
            string.Join(" · ", new[] { Titles.Tech(s.Tech), Titles.Source(s.Source), s.Device }.Where(x => x.Length > 0)),
            DurationFormat.Clock(s.Duration(nowTs)))).ToList();

        var today = Stats.Summarize(sessions, ReportRange.Today, now);
        TodayTotal = DurationFormat.Long(today.MergedTotal);
        Count = today.Count.ToString();
        SuccessCount = today.SuccessCount.ToString();
        Average = today.Count > 0 ? DurationFormat.Long(today.Average) : "–";
        Longest = today.Count > 0 ? DurationFormat.Long(today.Longest) : "–";

        TechChips = today.ByTech.Select(p => new Chip(Titles.Tech(p.Key), DurationFormat.Long(p.Value))).ToList();
        ShowTechChips = _techFilter.Key is null && TechChips.Count > 1;
        SourceChips = today.BySource.Select(p => new Chip(Titles.Source(p.Key), DurationFormat.Long(p.Value))).ToList();

        var days = Stats.DailyTotals(sessions, 7, now);
        double max = Math.Max(days.Max(d => d.Total), 60);
        Week = days.Select(d => new DayBar(
            ReportBuilder.Weekday(d.Day),
            d.Total >= 60 ? DurationFormat.Compact(d.Total) : "",
            Math.Max(d.Total > 0 ? 2 : 0, ChartHeight * d.Total / max),
            d.Day == now.Date,
            $"{ReportBuilder.ShortDay(d.Day)}: {DurationFormat.Long(d.Total)}")).ToList();

        double top = today.ByProject.Count > 0 ? Math.Max(today.ByProject[0].Value, 1) : 1;
        Projects = today.ByProject.Take(5)
            .Select(p => new ProjectRow(p.Key, DurationFormat.Long(p.Value), ProjectBarWidth * p.Value / top)).ToList();

        Recent = sessions.Where(s => !s.IsActive).Take(6).Select(s => new RecentRow(
            s.Status switch { "success" => "", "cancelled" => "", _ => "" },
            s.Status,
            s.Project,
            s.Kind,
            s.Kind != "run",
            Stats.FromUnix(s.Start).ToString("HH:mm"),
            DurationFormat.Long(s.Duration(nowTs)),
            string.Join(" · ", new[] { Titles.Status(s.Status), Titles.Tech(s.Tech), Titles.Source(s.Source), s.Device }.Where(x => x.Length > 0))
        )).ToList();

        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }
}
