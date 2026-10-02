package main

import (
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strings"
	"time"
)

// Rapor metni macOS uygulamasının "Raporu kopyala" çıktısıyla, CSV ise "CSV" dışa
// aktarımıyla aynı biçimdedir (ReportBuilder.swift).

var reportRanges = map[string]string{
	"today":     "Bugün",
	"yesterday": "Dün",
	"week":      "Bu hafta",
	"last7":     "Son 7 gün",
	"month":     "Bu ay",
	"lastmonth": "Geçen ay",
}

var techTitles = map[string]string{
	"flutter": "Flutter", "dotnet": ".NET", "react": "React", "next": "Next.js", "vite": "Vite", "other": "Diğer",
}

var sourceTitles = map[string]string{
	"terminal": "Terminal", "vscode": "VS Code", "cursor": "Cursor", "antigravity": "Antigravity",
	"rider": "Rider", "visualstudio": "Visual Studio", "other": "Diğer",
}

var statusTitles = map[string]string{
	"running": "Devam ediyor", "success": "Başarılı", "failed": "Başarısız", "cancelled": "İptal / tamamlanmadı",
}

func report(args []string) int {
	fs := flag.NewFlagSet("report", flag.ContinueOnError)
	rangeName := fs.String("range", "today", "today | yesterday | week | last7 | month | lastmonth")
	tech := fs.String("tech", "", "yalnızca bu teknoloji: flutter | dotnet | react | next | vite")
	csv := fs.Bool("csv", false, "metin yerine CSV bas")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if _, ok := reportRanges[*rangeName]; !ok {
		fmt.Fprintf(os.Stderr, "buildmeter: bilinmeyen aralık %q (today, yesterday, week, last7, month, lastmonth)\n", *rangeName)
		return 2
	}
	enableUTF8Console()

	now := time.Now()
	sessions := loadSessions(dataDir(), unix(now))
	if *tech != "" {
		var filtered []*Session
		for _, s := range sessions {
			if s.Tech == *tech {
				filtered = append(filtered, s)
			}
		}
		sessions = filtered
	}
	start, end := rangeInterval(*rangeName, now)
	if *csv {
		writeCSV(os.Stdout, sessions, start, end, now)
	} else {
		fmt.Fprintln(os.Stdout, reportText(sessions, *rangeName, *tech, start, end, now))
	}
	return 0
}

func unix(t time.Time) float64 { return float64(t.UnixMicro()) / 1e6 }

func startOfDay(t time.Time) time.Time {
	y, m, d := t.Date()
	return time.Date(y, m, d, 0, 0, 0, 0, t.Location())
}

// rangeInterval, aralığı yerel saatle hesaplar; haftalar pazartesi başlar.
func rangeInterval(name string, now time.Time) (time.Time, time.Time) {
	today := startOfDay(now)
	switch name {
	case "yesterday":
		return today.AddDate(0, 0, -1), today
	case "week":
		offset := (int(today.Weekday()) + 6) % 7
		start := today.AddDate(0, 0, -offset)
		return start, start.AddDate(0, 0, 7)
	case "last7":
		return today.AddDate(0, 0, -6), today.AddDate(0, 0, 1)
	case "month":
		start := time.Date(today.Year(), today.Month(), 1, 0, 0, 0, 0, today.Location())
		return start, start.AddDate(0, 1, 0)
	case "lastmonth":
		start := time.Date(today.Year(), today.Month()-1, 1, 0, 0, 0, 0, today.Location())
		return start, start.AddDate(0, 1, 0)
	}
	return today, today.AddDate(0, 0, 1)
}

func reportText(sessions []*Session, rangeName, tech string, start, end, now time.Time) string {
	s := summarize(sessions, unix(start), unix(end), unix(now))
	var lines []string
	scope := ""
	if tech != "" {
		scope = title(techTitles, tech) + " "
	}
	lines = append(lines, fmt.Sprintf("BuildMeter · %sBuild Bekleme Raporu (%s)", scope, reportRanges[rangeName]))
	if rangeName == "today" || rangeName == "yesterday" {
		lines = append(lines, longDay(start))
	} else {
		lines = append(lines, shortDay(start)+" – "+shortDay(end.Add(-time.Second)))
	}
	lines = append(lines, "")
	lines = append(lines, "• Toplam bekleme süresi: "+longDuration(s.MergedTotal))
	if s.SumTotal-s.MergedTotal > 60 {
		lines = append(lines, "  (eşzamanlı build'ler tek sayıldı; düz toplam "+longDuration(s.SumTotal)+")")
	}
	running := 0
	for _, x := range s.Sessions {
		if x.Active() {
			running++
		}
	}
	failed := s.Count - s.SuccessCount - running
	parts := []string{fmt.Sprintf("%d başarılı", s.SuccessCount)}
	if failed > 0 {
		parts = append(parts, fmt.Sprintf("%d başarısız/iptal", failed))
	}
	if running > 0 {
		parts = append(parts, fmt.Sprintf("%d devam ediyor", running))
	}
	lines = append(lines, fmt.Sprintf("• Build sayısı: %d (%s)", s.Count, strings.Join(parts, ", ")))
	if s.Count > 0 {
		lines = append(lines, "• Ortalama build süresi: "+longDuration(s.Average))
		lines = append(lines, "• En uzun build: "+longDuration(s.Longest))
	}

	if rangeName != "today" && rangeName != "yesterday" {
		var days []dayTotal
		for _, d := range dailyBreakdown(sessions, start, end, now) {
			if d.total > 0 {
				days = append(days, d)
			}
		}
		if len(days) > 0 {
			lines = append(lines, "• Build yapılan gün başına ortalama: "+longDuration(s.MergedTotal/float64(len(days))))
			lines = append(lines, "", "Günlük dağılım:")
			for _, d := range days {
				lines = append(lines, fmt.Sprintf("  - %s: %s", shortDay(d.day), longDuration(d.total)))
			}
		}
	}

	if tech == "" && len(s.ByTech) > 0 {
		lines = append(lines, "", "Teknolojiye göre:")
		for _, p := range s.ByTech {
			lines = append(lines, fmt.Sprintf("  - %s: %s (%d build)", title(techTitles, p.Key), longDuration(p.Value),
				countWhere(s.Sessions, func(x *Session) bool { return x.Tech == p.Key })))
		}
	}
	machines := map[string]bool{}
	for _, x := range s.Sessions {
		machines[machine(x)] = true
	}
	if len(machines) > 1 {
		names := make([]string, 0, len(machines))
		for m := range machines {
			names = append(names, m)
		}
		sort.Strings(names)
		lines = append(lines, "", "Makineye göre:")
		for _, m := range names {
			var intervals [][2]float64
			for _, x := range s.Sessions {
				if machine(x) == m {
					if a, b, ok := x.clipped(unix(start), unix(end), unix(now)); ok {
						intervals = append(intervals, [2]float64{a, b})
					}
				}
			}
			lines = append(lines, fmt.Sprintf("  - %s: %s", m, longDuration(mergedDuration(intervals))))
		}
	}
	if len(s.BySource) > 0 {
		lines = append(lines, "", "Kaynağa göre:")
		for _, p := range s.BySource {
			lines = append(lines, fmt.Sprintf("  - %s: %s", title(sourceTitles, p.Key), longDuration(p.Value)))
		}
	}
	if len(s.ByProject) > 0 {
		lines = append(lines, "", "Projeye göre:")
		for _, p := range s.ByProject {
			lines = append(lines, fmt.Sprintf("  - %s: %s (%d build)", p.Key, longDuration(p.Value),
				countWhere(s.Sessions, func(x *Session) bool { return x.Project == p.Key })))
		}
	}
	return strings.Join(lines, "\n")
}

func writeCSV(w io.Writer, sessions []*Session, start, end, now time.Time) {
	s := summarize(sessions, unix(start), unix(end), unix(now))
	sorted := append([]*Session(nil), s.Sessions...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Start < sorted[j].Start })
	// Excel Türkçe yerel ayarı için UTF-8 BOM + noktalı virgül.
	fmt.Fprint(w, "\uFEFFbaslangic;bitis;sure_sn;sure;proje;teknoloji;arac;kaynak;tur;cihaz;durum;makine\n")
	for _, x := range sorted {
		d := x.endOr(unix(now)) - x.Start
		endText := ""
		if x.End != nil {
			endText = csvTime(*x.End)
		}
		row := []string{
			csvTime(x.Start), endText, fmt.Sprint(int(math.Round(d))), longDuration(d), x.Project,
			title(techTitles, x.Tech), x.Tool, title(sourceTitles, x.Source), x.Kind, x.Device,
			title(statusTitles, x.Status), machine(x),
		}
		for i, v := range row {
			row[i] = csvEscape(v)
		}
		fmt.Fprintln(w, strings.Join(row, ";"))
	}
}

type dayTotal struct {
	day   time.Time
	total float64
}

func dailyBreakdown(sessions []*Session, start, end, now time.Time) []dayTotal {
	var result []dayTotal
	for day := start; day.Before(end) && !day.After(now); day = day.AddDate(0, 0, 1) {
		next := day.AddDate(0, 0, 1)
		var intervals [][2]float64
		for _, s := range sessions {
			if a, b, ok := s.clipped(unix(day), unix(next), unix(now)); ok {
				intervals = append(intervals, [2]float64{a, b})
			}
		}
		result = append(result, dayTotal{day, mergedDuration(intervals)})
	}
	return result
}

// MARK: - Biçimlendirme

// longDuration: "1 sa 23 dk", "4 dk 05 sn", "42 sn"
func longDuration(t float64) string {
	s := int(math.Max(0, math.Round(t)))
	h, m, sec := s/3600, (s%3600)/60, s%60
	switch {
	case h > 0:
		return fmt.Sprintf("%d sa %d dk", h, m)
	case m > 0:
		return fmt.Sprintf("%d dk %02d sn", m, sec)
	}
	return fmt.Sprintf("%d sn", sec)
}

var (
	monthsLong  = []string{"Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"}
	monthsShort = []string{"Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"}
	daysLong    = []string{"Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"}
	daysShort   = []string{"Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"}
)

// longDay: "2 Ekim 2026, Cuma"
func longDay(t time.Time) string {
	return fmt.Sprintf("%d %s %d, %s", t.Day(), monthsLong[t.Month()-1], t.Year(), daysLong[t.Weekday()])
}

// shortDay: "2 Eki Cum"
func shortDay(t time.Time) string {
	return fmt.Sprintf("%d %s %s", t.Day(), monthsShort[t.Month()-1], daysShort[t.Weekday()])
}

func csvTime(ts float64) string {
	return time.UnixMicro(int64(math.Round(ts * 1e6))).Local().Format("2006-01-02 15:04:05")
}

func csvEscape(v string) string {
	if !strings.ContainsAny(v, ";\"\n") {
		return v
	}
	return `"` + strings.ReplaceAll(v, `"`, `""`) + `"`
}

func title(titles map[string]string, key string) string {
	if t, ok := titles[key]; ok {
		return t
	}
	return titles["other"]
}

func machine(s *Session) string {
	if s.Host != "" {
		return s.Host
	}
	return hostName()
}

func countWhere(sessions []*Session, f func(*Session) bool) int {
	n := 0
	for _, s := range sessions {
		if f(s) {
			n++
		}
	}
	return n
}
