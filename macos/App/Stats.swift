import Foundation

enum ReportRange: String, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, last7Days, thisMonth, lastMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Bugün"
        case .yesterday: return "Dün"
        case .thisWeek: return "Bu hafta"
        case .last7Days: return "Son 7 gün"
        case .thisMonth: return "Bu ay"
        case .lastMonth: return "Geçen ay"
        }
    }
}

struct Summary {
    var range: ReportRange
    var interval: DateInterval
    var sessions: [BuildSession]
    /// Eşzamanlı build'ler birleştirilerek hesaplanan gerçek bekleme süresi.
    var mergedTotal: TimeInterval
    /// Tüm build sürelerinin düz toplamı.
    var sumTotal: TimeInterval
    var count: Int
    var successCount: Int
    var longest: TimeInterval
    var average: TimeInterval
    var bySource: [(key: BuildSource, value: TimeInterval)]
    var byTech: [(key: BuildTech, value: TimeInterval)]
    var byProject: [(key: String, value: TimeInterval)]
}

/// Oturum listesi üzerinde zaman aralığı istatistikleri.
struct Stats {
    let sessions: [BuildSession]
    let now: Date
    /// Seçili teknoloji filtresi; `nil` tümü demektir.
    var tech: BuildTech?
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "tr_TR")
        c.firstWeekday = 2 // Pazartesi
        return c
    }()

    init(sessions: [BuildSession], now: Date, tech: BuildTech? = nil) {
        self.sessions = tech.map { t in sessions.filter { $0.tech == t } } ?? sessions
        self.now = now
        self.tech = tech
    }

    func range(_ r: ReportRange) -> (range: ReportRange, interval: DateInterval) {
        let cal = calendar
        let startOfToday = cal.startOfDay(for: now)
        let interval: DateInterval
        switch r {
        case .today:
            interval = DateInterval(start: startOfToday, end: cal.date(byAdding: .day, value: 1, to: startOfToday)!)
        case .yesterday:
            interval = DateInterval(start: cal.date(byAdding: .day, value: -1, to: startOfToday)!, end: startOfToday)
        case .thisWeek:
            interval = cal.dateInterval(of: .weekOfYear, for: now)!
        case .last7Days:
            interval = DateInterval(start: cal.date(byAdding: .day, value: -6, to: startOfToday)!,
                                    end: cal.date(byAdding: .day, value: 1, to: startOfToday)!)
        case .thisMonth:
            interval = cal.dateInterval(of: .month, for: now)!
        case .lastMonth:
            let prev = cal.date(byAdding: .month, value: -1, to: now)!
            interval = cal.dateInterval(of: .month, for: prev)!
        }
        return (r, interval)
    }

    func summary(_ r: ReportRange, includeActive: Bool = true) -> Summary {
        summary(for: range(r), includeActive: includeActive)
    }

    func summary(for r: (range: ReportRange, interval: DateInterval), includeActive: Bool = true) -> Summary {
        let window = r.interval
        let relevant = sessions.filter { (includeActive || !$0.isActive) && $0.interval(clippedTo: window, now: now) != nil }
        let clipped = relevant.compactMap { $0.interval(clippedTo: window, now: now) }

        var bySource: [BuildSource: TimeInterval] = [:]
        var byTech: [BuildTech: TimeInterval] = [:]
        var byProject: [String: TimeInterval] = [:]
        for s in relevant {
            let d = s.interval(clippedTo: window, now: now)?.duration ?? 0
            bySource[s.source, default: 0] += d
            byTech[s.tech, default: 0] += d
            byProject[s.project, default: 0] += d
        }
        let finished = relevant.filter { !$0.isActive }
        let durations = finished.map { $0.duration(now: now) }
        return Summary(
            range: r.range,
            interval: window,
            sessions: relevant,
            mergedTotal: Self.mergedDuration(clipped),
            sumTotal: clipped.reduce(0) { $0 + $1.duration },
            count: relevant.count,
            successCount: relevant.filter { $0.status == .success }.count,
            longest: durations.max() ?? 0,
            average: durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count),
            bySource: bySource.sorted { $0.value > $1.value },
            byTech: byTech.sorted { $0.value > $1.value },
            byProject: byProject.sorted { $0.value > $1.value }
        )
    }

    /// Son `days` günün (bugün dahil) birleştirilmiş günlük toplamları, eskiden yeniye.
    func dailyTotals(days: Int, includeActive: Bool = true) -> [(day: Date, total: TimeInterval)] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().map { offset in
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            let window = DateInterval(start: start, end: end)
            let clipped = sessions
                .filter { includeActive || !$0.isActive }
                .compactMap { $0.interval(clippedTo: window, now: now) }
            return (start, Self.mergedDuration(clipped))
        }
    }

    /// Örtüşen aralıkları birleştirip toplam süreyi döndürür.
    static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for i in sorted {
            if let c = current, i.start <= c.end {
                current = DateInterval(start: c.start, end: max(c.end, i.end))
            } else {
                if let c = current { total += c.duration }
                current = i
            }
        }
        if let c = current { total += c.duration }
        return total
    }
}
