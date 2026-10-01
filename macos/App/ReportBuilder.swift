import AppKit
import UniformTypeIdentifiers

/// Yönetime iletilecek metin ve CSV raporlarını üretir.
enum ReportBuilder {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy, EEEE"
        return f
    }()

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM EEE"
        return f
    }()

    private static let csvDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func text(stats: Stats, range: ReportRange) -> String {
        let s = stats.summary(range)
        let lastDay = s.interval.end.addingTimeInterval(-1)
        let period = s.range == .today || s.range == .yesterday
            ? dayFormatter.string(from: s.interval.start)
            : "\(shortDay.string(from: s.interval.start)) – \(shortDay.string(from: lastDay))"

        var lines: [String] = []
        lines.append("BuildMeter · Flutter Build Bekleme Raporu (\(s.range.title))")
        lines.append(period)
        lines.append("")
        lines.append("• Toplam bekleme süresi: \(DurationFormat.long(s.mergedTotal))")
        if s.sumTotal - s.mergedTotal > 60 {
            lines.append("  (eşzamanlı build'ler tek sayıldı; düz toplam \(DurationFormat.long(s.sumTotal)))")
        }
        let running = s.sessions.filter(\.isActive).count
        let failed = s.count - s.successCount - running
        var parts = ["\(s.successCount) başarılı"]
        if failed > 0 { parts.append("\(failed) başarısız/iptal") }
        if running > 0 { parts.append("\(running) devam ediyor") }
        lines.append("• Build sayısı: \(s.count) (\(parts.joined(separator: ", ")))")
        if s.count > 0 {
            lines.append("• Ortalama build süresi: \(DurationFormat.long(s.average))")
            lines.append("• En uzun build: \(DurationFormat.long(s.longest))")
        }

        if range != .today && range != .yesterday {
            let days = dailyBreakdown(stats: stats, interval: s.interval)
                .filter { $0.total > 0 }
            if !days.isEmpty {
                let workdays = Double(days.count)
                lines.append("• Build yapılan gün başına ortalama: \(DurationFormat.long(s.mergedTotal / workdays))")
                lines.append("")
                lines.append("Günlük dağılım:")
                for d in days {
                    lines.append("  - \(shortDay.string(from: d.day)): \(DurationFormat.long(d.total))")
                }
            }
        }

        if !s.bySource.isEmpty {
            lines.append("")
            lines.append("Kaynağa göre:")
            for (source, t) in s.bySource {
                lines.append("  - \(source.title): \(DurationFormat.long(t))")
            }
        }
        if !s.byProject.isEmpty {
            lines.append("")
            lines.append("Projeye göre:")
            for (project, t) in s.byProject {
                let n = s.sessions.filter { $0.project == project }.count
                lines.append("  - \(project): \(DurationFormat.long(t)) (\(n) build)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func csv(stats: Stats, range: ReportRange) -> String {
        let s = stats.summary(range)
        var rows = ["baslangic;bitis;sure_sn;sure;proje;kaynak;tur;cihaz;durum"]
        for session in s.sessions.sorted(by: { $0.start < $1.start }) {
            let d = session.duration(now: stats.now)
            rows.append([
                csvDate.string(from: session.start),
                session.end.map(csvDate.string(from:)) ?? "",
                String(Int(d.rounded())),
                DurationFormat.long(d),
                session.project,
                session.source.title,
                session.kind,
                session.device ?? "",
                session.status.title,
            ].map(escape).joined(separator: ";"))
        }
        // Excel Türkçe yerel ayarı için UTF-8 BOM + noktalı virgül.
        return "\u{FEFF}" + rows.joined(separator: "\n") + "\n"
    }

    static func dailyBreakdown(stats: Stats, interval: DateInterval) -> [(day: Date, total: TimeInterval)] {
        var result: [(Date, TimeInterval)] = []
        var day = interval.start
        while day < interval.end && day <= stats.now {
            let next = stats.calendar.date(byAdding: .day, value: 1, to: day)!
            let window = DateInterval(start: day, end: next)
            let clipped = stats.sessions.compactMap { $0.interval(clippedTo: window, now: stats.now) }
            result.append((day, Stats.mergedDuration(clipped)))
            day = next
        }
        return result
    }

    @MainActor
    static func copyText(stats: Stats, range: ReportRange) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(stats: stats, range: range), forType: .string)
    }

    @MainActor
    static func exportCSV(stats: Stats, range: ReportRange) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "flutter-build-raporu-\(range.rawValue)-\(f.string(from: stats.now)).csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv(stats: stats, range: range).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
