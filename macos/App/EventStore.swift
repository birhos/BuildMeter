import Foundation
import WidgetKit

/// Terminal wrapper'ı ve VS Code/Cursor eklentisinin yazdığı olay dosyasını izler,
/// oturumları üretir ve widget için özet yazar.
@MainActor
final class EventStore: ObservableObject {
    static let dataDirectory: URL = {
        if let custom = ProcessInfo.processInfo.environment["BUILDMETER_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buildmeter", isDirectory: true)
    }()
    static let eventsURL = dataDirectory.appendingPathComponent("events.jsonl")

    /// Bitişi gelmeyen ve süreci de bilinmeyen oturumlar bu süreden sonra yok sayılır.
    private static let staleAfter: TimeInterval = 3 * 3600

    @Published private(set) var sessions: [BuildSession] = []
    @Published private(set) var now = Date()

    private var byID: [String: BuildSession] = [:]
    private var readOffset: UInt64 = 0
    private var pendingTail = Data()
    private var timer: Timer?
    private var lastSnapshotKey = ""
    private var tickCount = 0

    var active: [BuildSession] { sessions.filter(\.isActive) }

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.eventsURL.path) {
            fm.createFile(atPath: Self.eventsURL.path, contents: nil)
        }
        readNewEvents()
        publish()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reloadAll() {
        byID = [:]
        readOffset = 0
        pendingTail = Data()
        readNewEvents()
        publish()
    }

    private func tick() {
        tickCount += 1
        let changed = readNewEvents()
        // Aktif build varken saniyede bir, yoksa 30 sn'de bir arayüzü tazele.
        if changed || !active.isEmpty || tickCount % 30 == 0 {
            if tickCount % 10 == 0 { expireDeadSessions() }
            publish()
        }
    }

    // MARK: - Dosya okuma

    @discardableResult
    private func readNewEvents() -> Bool {
        let url = Self.eventsURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { return false }

        if size < readOffset { // dosya kesilmiş/yeniden yazılmış
            byID = [:]
            readOffset = 0
            pendingTail = Data()
        }
        guard size > readOffset, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let chunk = try handle.readToEnd() ?? Data()
            readOffset += UInt64(chunk.count)
            var data = pendingTail + chunk
            // Yarım yazılmış son satırı bir sonraki okumaya bırak.
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                pendingTail = data[(lastNewline + 1)...]
                data = data[..<lastNewline]
            } else {
                pendingTail = data
                return false
            }
            let decoder = JSONDecoder()
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let event = try? decoder.decode(RawEvent.self, from: Data(line)) {
                    apply(event)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func apply(_ e: RawEvent) {
        let ts = Date(timeIntervalSince1970: e.ts)
        switch e.event {
        case "start":
            byID[e.id] = BuildSession(
                id: e.id, source: BuildSource(raw: e.source), kind: e.kind ?? "run",
                project: e.project ?? "?", device: e.device,
                start: ts, end: nil, status: .running, pid: e.pid
            )
        case "end":
            var session = byID[e.id] ?? BuildSession(
                id: e.id, source: BuildSource(raw: e.source), kind: e.kind ?? "run",
                project: e.project ?? "?", device: e.device,
                start: e.start.map(Date.init(timeIntervalSince1970:)) ?? ts,
                end: nil, status: .running, pid: nil
            )
            if let start = e.start { session.start = Date(timeIntervalSince1970: start) }
            if let device = e.device, !device.isEmpty { session.device = device }
            if let project = e.project, !project.isEmpty { session.project = project }
            session.end = max(ts, session.start)
            session.status = BuildStatus(rawValue: e.status ?? "") ?? .failed
            if session.status == .running { session.status = .failed }
            byID[e.id] = session
        case "discard":
            byID[e.id] = nil
        default:
            break
        }
    }

    /// Terminal kapatıldığında ya da editör çöktüğünde "end" gelmez.
    /// Süreci ölmüş veya çok eski aktif oturumları listeden çıkar.
    private func expireDeadSessions() {
        let now = Date()
        for (id, s) in byID where s.isActive {
            let tooOld = now.timeIntervalSince(s.start) > Self.staleAfter
            let dead = s.pid.map { kill($0, 0) != 0 && errno == ESRCH } ?? false
            if tooOld || dead { byID[id] = nil }
        }
    }

    // MARK: - Yayınlama

    private func publish() {
        now = Date()
        sessions = byID.values.sorted { $0.start > $1.start }
        writeSnapshotIfNeeded()
    }

    private func writeSnapshotIfNeeded() {
        let stats = Stats(sessions: sessions, now: now)
        let today = stats.range(.today)
        let finished = sessions.filter { !$0.isActive }
        let key = "\(today.interval.start.timeIntervalSince1970)|\(finished.count)|\(active.map(\.id).joined())"
        guard key != lastSnapshotKey else { return }
        lastSnapshotKey = key

        let todaySummary = stats.summary(for: today, includeActive: false)
        let snapshot = WidgetSnapshot(
            generatedAt: now,
            day: today.interval.start,
            todayTotal: todaySummary.mergedTotal,
            todayCount: todaySummary.count,
            todaySuccess: todaySummary.successCount,
            todayLongest: todaySummary.longest,
            active: active.map { .init(project: $0.project, source: $0.source, start: $0.start) },
            week: stats.dailyTotals(days: 7, includeActive: false).map { .init(day: $0.day, total: $0.total) },
            topProjects: todaySummary.byProject.prefix(4).map { .init(project: $0.key, total: $0.value) }
        )
        SharedStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
    }
}
