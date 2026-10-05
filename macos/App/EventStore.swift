import Foundation
import WidgetKit

/// Toplayıcıların (terminal wrapper'ı, editör eklentisi, MSBuild hook'u) yazdığı olay
/// dosyalarını izler, oturumları üretir ve widget için özet yazar.
///
/// Okunan dosyalar: `events.jsonl` ve makine başına yazılan `events-<host>.jsonl`.
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

    static func isEventsFile(_ name: String) -> Bool {
        name.hasPrefix("events") && name.hasSuffix(".jsonl")
    }

    /// Bitişi gelmeyen ve süreci de bilinmeyen oturumlar bu süreden sonra yok sayılır.
    private static let staleAfter: TimeInterval = 3 * 3600

    @Published private(set) var sessions: [BuildSession] = []
    @Published private(set) var now = Date()

    private struct FileCursor {
        var offset: UInt64 = 0
        var pendingTail = Data()
    }

    private var log = EventLog()
    private var cursors: [String: FileCursor] = [:]
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
        resetLog()
        readNewEvents()
        publish()
    }

    private func resetLog() {
        log = EventLog()
        cursors = [:]
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
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.dataDirectory.path)) ?? [])
            .filter(Self.isEventsFile)
            .sorted()
        var sizes: [String: UInt64] = [:]
        for name in names {
            let path = Self.dataDirectory.appendingPathComponent(name).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                sizes[name] = size.uint64Value
            }
        }

        // Bir dosya kesildi, yeniden yazıldı ya da silindiyse her şeyi baştan oku.
        let shrunk = cursors.contains { name, cursor in (sizes[name] ?? 0) < cursor.offset }
        if shrunk { resetLog() }

        var changed = shrunk
        for name in names {
            if let size = sizes[name], readFile(name, size: size) { changed = true }
        }
        return changed
    }

    private func readFile(_ name: String, size: UInt64) -> Bool {
        var cursor = cursors[name] ?? FileCursor()
        guard size > cursor.offset,
              let handle = try? FileHandle(forReadingFrom: Self.dataDirectory.appendingPathComponent(name))
        else { return false }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: cursor.offset)
            let chunk = try handle.readToEnd() ?? Data()
            cursor.offset += UInt64(chunk.count)
            var data = cursor.pendingTail + chunk
            // Yarım yazılmış son satırı bir sonraki okumaya bırak.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
                cursor.pendingTail = data
                cursors[name] = cursor
                return false
            }
            cursor.pendingTail = data[(lastNewline + 1)...]
            data = data[..<lastNewline]
            cursors[name] = cursor
            log.ingest(data)
            return true
        } catch {
            return false
        }
    }

    /// Terminal kapatıldığında ya da editör çöktüğünde "end" gelmez.
    /// Süreci ölmüş veya çok eski aktif oturumları listeden çıkar. MSBuild kayıtlarını
    /// `SessionMerger` başarısız olarak kapatır, bu yüzden onlar burada silinmez.
    private func expireDeadSessions() {
        let now = Date()
        for (id, s) in log.byID where s.isActive && !s.isMSBuild {
            let tooOld = now.timeIntervalSince(s.start) > Self.staleAfter
            let dead = s.pid.map { kill($0, 0) != 0 && errno == ESRCH } ?? false
            if tooOld || dead { log.remove(id: id) }
        }
    }

    // MARK: - Yayınlama

    private func publish() {
        now = Date()
        sessions = SessionMerger.sessions(from: Array(log.byID.values), now: now)
            .sorted { $0.start > $1.start }
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
            active: active.map { .init(project: $0.project, source: $0.source, tech: $0.tech, start: $0.start) },
            week: stats.dailyTotals(days: 7, includeActive: false).map { .init(day: $0.day, total: $0.total) },
            topProjects: todaySummary.byProject.prefix(4).map { .init(project: $0.key, total: $0.value) }
        )
        SharedStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
    }
}
