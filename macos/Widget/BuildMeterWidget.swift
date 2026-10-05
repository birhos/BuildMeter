import SwiftUI
import WidgetKit

struct BuildEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    var hasData = true

    /// Gün değiştiyse eski "bugün" değerlerini gösterme.
    var isCurrentDay: Bool { Calendar.current.isDate(snapshot.day, inSameDayAs: date) }
    var todayTotal: TimeInterval { isCurrentDay ? snapshot.todayTotal : 0 }
    var todayCount: Int { isCurrentDay ? snapshot.todayCount : 0 }
}

struct BuildTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BuildEntry {
        BuildEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BuildEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : (SharedStore.read() ?? .empty)
        completion(BuildEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BuildEntry>) -> Void) {
        let now = Date()
        let stored = SharedStore.read()
        let entry = BuildEntry(date: now, snapshot: stored ?? .empty, hasData: stored != nil)
        // Uygulama değişiklikte zaten yeniler; bu yalnızca gece yarısı/yedek tazeleme.
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now
        let next = min(midnight.addingTimeInterval(5), now.addingTimeInterval(15 * 60))
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct BuildMeterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BuildEntry

    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.needle.fill")
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.23, green: 0.48, blue: 1), Color(red: 1, green: 0.33, blue: 0.21)], startPoint: .leading, endPoint: .trailing))
                Text("Build bekleme").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Bugün").font(.caption2).foregroundStyle(.secondary)
            Text(DurationFormat.long(entry.todayTotal))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !entry.hasData {
                Text("Veri yok — uygulamayı açın").font(.caption2).foregroundStyle(.red)
            } else if let active = entry.snapshot.active.first {
                activeRow(active)
            } else {
                Text("\(entry.todayCount) build").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            small
            VStack(alignment: .leading, spacing: 4) {
                Text("Son 7 gün").font(.caption2).foregroundStyle(.secondary)
                weekBars
                if !entry.isCurrentDay || entry.snapshot.topProjects.isEmpty {
                    Spacer(minLength: 0)
                } else {
                    ForEach(entry.snapshot.topProjects.prefix(2), id: \.project) { p in
                        HStack {
                            Text(p.project).lineLimit(1)
                            Spacer()
                            Text(DurationFormat.compact(p.total)).foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var weekBars: some View {
        let week = entry.snapshot.week
        let maxTotal = max(week.map(\.total).max() ?? 1, 60)
        let dayLetter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "tr_TR")
            f.dateFormat = "EEEEE"
            return f
        }()
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(week, id: \.day) { d in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Calendar.current.isDate(d.day, inSameDayAs: entry.date) ? Color.blue : Color.blue.opacity(0.45))
                                .frame(height: max(2, geo.size.height * d.total / maxTotal))
                        }
                    }
                    Text(dayLetter.string(from: d.day)).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func activeRow(_ active: WidgetSnapshot.Active) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hourglass").foregroundStyle(.orange)
            Text(active.project).lineLimit(1)
            Spacer(minLength: 2)
            Text(active.start, style: .timer)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.orange)
                .frame(maxWidth: 52, alignment: .trailing)
        }
        .font(.caption)
    }
}

struct BuildMeterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: BuildTimelineProvider()) { entry in
            BuildMeterWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("BuildMeter")
        .description("Bugün build beklerken geçen süre ve son 7 gün.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct BuildMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        BuildMeterWidget()
    }
}

extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        let today = Calendar.current.startOfDay(for: Date())
        let minutes: [Double] = [42, 65, 30, 88, 51, 12, 47]
        return WidgetSnapshot(
            generatedAt: Date(), day: today,
            todayTotal: 47 * 60, todayCount: 9, todaySuccess: 8, todayLongest: 9 * 60,
            active: [],
            week: minutes.enumerated().map { i, m in
                .init(day: Calendar.current.date(byAdding: .day, value: i - 6, to: today)!, total: m * 60)
            },
            topProjects: [.init(project: "musteri_app", total: TimeInterval(30 * 60)), .init(project: "kurye_app", total: TimeInterval(17 * 60))]
        )
    }
}
