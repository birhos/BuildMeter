import Foundation

enum BuildStatus: String, Codable {
    case running
    case success
    case failed
    case cancelled

    var title: String {
        switch self {
        case .running: return "Devam ediyor"
        case .success: return "Başarılı"
        case .failed: return "Başarısız"
        case .cancelled: return "İptal / tamamlanmadı"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }
}

/// Bir `flutter run` / `flutter build` / debug oturumunun bekleme süresi.
struct BuildSession: Identifiable, Hashable {
    let id: String
    var source: BuildSource
    var kind: String          // "run" | "build"
    var project: String
    var device: String?
    var start: Date
    var end: Date?
    var status: BuildStatus
    var pid: Int32?

    var isActive: Bool { end == nil }

    func duration(now: Date) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }

    /// Aralığın verilen pencere ile kesişimi.
    func interval(clippedTo range: DateInterval, now: Date) -> DateInterval? {
        let s = max(start, range.start)
        let e = min(end ?? now, range.end)
        return e > s ? DateInterval(start: s, end: e) : nil
    }
}

/// `~/.buildmeter/events.jsonl` satırlarının biçimi.
///
///     {"event":"start","id":"…","source":"terminal","kind":"run","project":"app","device":"ios","ts":1759340000.1,"pid":123}
///     {"event":"end","id":"…","source":"terminal","kind":"run","project":"app","device":"ios","start":1759340000.1,"ts":1759340090.4,"status":"success"}
struct RawEvent: Decodable {
    var event: String
    var id: String
    var source: String?
    var kind: String?
    var project: String?
    var device: String?
    var ts: Double
    var start: Double?
    var status: String?
    var pid: Int32?
}
