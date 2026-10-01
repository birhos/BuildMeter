import Darwin
import Foundation

/// Build'i başlatan araç.
enum BuildSource: String, Codable, CaseIterable, Hashable {
    case terminal
    case vscode
    case cursor
    case other

    init(raw: String?) {
        self = BuildSource(rawValue: raw ?? "") ?? .other
    }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .other: return "Diğer"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .other: return "questionmark.circle"
        }
    }
}

/// Widget'ın App Group üzerinden okuduğu özet veri. Menü bar uygulaması yazar.
struct WidgetSnapshot: Codable {
    struct Active: Codable, Hashable {
        var project: String
        var source: BuildSource
        var start: Date
    }

    struct DayTotal: Codable, Hashable {
        var day: Date
        var total: TimeInterval
    }

    struct ProjectTotal: Codable, Hashable {
        var project: String
        var total: TimeInterval
    }

    var generatedAt: Date
    var day: Date
    var todayTotal: TimeInterval
    var todayCount: Int
    var todaySuccess: Int
    var todayLongest: TimeInterval
    var active: [Active]
    var week: [DayTotal]
    var topProjects: [ProjectTotal]

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast, day: Calendar.current.startOfDay(for: Date()),
        todayTotal: 0, todayCount: 0, todaySuccess: 0, todayLongest: 0,
        active: [], week: [], topProjects: []
    )
}

enum SharedStore {
    static let snapshotFileName = "snapshot.json"
    static let widgetKind = "BuildMeterWidget"

    /// Info.plist'teki AppGroupID, build sırasında `$(TeamIdentifierPrefix)` ile genişletilir.
    static var appGroupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
    }

    /// App Group konteyneri (uygulama Team ID ile imzalandıysa kullanılabilir).
    static var groupSnapshotURL: URL? {
        guard let id = appGroupID,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
        else { return nil }
        return dir.appendingPathComponent(snapshotFileName)
    }

    /// `~/.buildmeter/widget-snapshot.json` — yerel imzalı (ad-hoc) kurulumda
    /// App Group erişilemediği için widget bu dosyayı okur (sandbox istisnası ile).
    static var homeSnapshotURL: URL {
        realHomeDirectory
            .appendingPathComponent(".buildmeter", isDirectory: true)
            .appendingPathComponent("widget-snapshot.json")
    }

    /// Sandbox içindeyken de kullanıcının gerçek ev dizini.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func write(_ snapshot: WidgetSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        for url in [homeSnapshotURL, groupSnapshotURL].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Okunabilen kopyalardan en yenisini döndürür.
    static func read() -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return [homeSnapshotURL, groupSnapshotURL]
            .compactMap { $0 }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(WidgetSnapshot.self, from: $0) }
            .max { $0.generatedAt < $1.generatedAt }
    }
}

enum DurationFormat {
    /// "1 sa 23 dk", "4 dk 05 sn", "42 sn"
    static func long(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h) sa \(m) dk" }
        if m > 0 { return String(format: "%d dk %02d sn", m, sec) }
        return "\(sec) sn"
    }

    /// Menü bar için kısa biçim: "1s23d", "12d", "42sn"
    static func compact(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return String(format: "%ds%02dd", h, m) }
        if m > 0 { return "\(m)dk" }
        return "\(s)sn"
    }

    /// Canlı sayaç: "02:15", "1:02:15"
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}
