import Foundation

/// Olay satırlarından ham oturumları üretir. Dosya ve zamanlayıcıdan bağımsızdır,
/// bu yüzden fixture testleri aynı mantığı doğrudan çalıştırır.
struct EventLog {
    private(set) var byID: [String: BuildSession] = [:]

    /// Tam satırlardan oluşan veriyi uygular; bozuk satırlar atlanır.
    mutating func ingest(_ data: Data) {
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            if let event = try? decoder.decode(RawEvent.self, from: Data(line)) {
                apply(event)
            }
        }
    }

    mutating func apply(_ e: RawEvent) {
        let ts = Date(timeIntervalSince1970: e.ts)
        switch e.event {
        case "start":
            // Aynı id başka bir dosyada ya da tekrar okunduysa biten oturumu geri açma.
            if byID[e.id]?.end != nil { return }
            byID[e.id] = session(from: e, start: ts)
        case "end":
            var session = byID[e.id] ?? session(from: e, start: e.start.map(Date.init(timeIntervalSince1970:)) ?? ts)
            if let start = e.start { session.start = Date(timeIntervalSince1970: start) }
            if let device = e.device, !device.isEmpty { session.device = device }
            if let project = e.project, !project.isEmpty { session.project = project }
            if let group = e.group, !group.isEmpty { session.group = group }
            session.pid = nil
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

    mutating func remove(id: String) {
        byID[id] = nil
    }

    private func session(from e: RawEvent, start: Date) -> BuildSession {
        BuildSession(
            id: e.id, source: BuildSource(raw: e.source), tech: BuildTech(raw: e.tech),
            tool: e.tool.nonEmpty, group: e.group.nonEmpty, host: e.host.nonEmpty,
            solution: e.solution.nonEmpty, kind: e.kind ?? "run", project: e.project ?? "?",
            device: e.device, start: start, end: nil, status: .running, pid: e.pid
        )
    }
}

/// Ham oturumları gösterilecek oturumlara dönüştürür:
///
/// - Aynı `group` id'li kayıtlar (solution build'indeki projeler, wrapper'ın kaydı) tek oturumdur.
/// - Grupsuz MSBuild kayıtları aynı kaynak, makine ve çözüm için aralarında
///   `msbuildGap`'ten az boşluk varsa tek oturumda birleşir.
/// - Başarısız MSBuild build'inde `end` gelmez. Açık kalan MSBuild oturumu aynı kaynaktan
///   yeni bir build başlayınca ya da son etkinlikten `msbuildOpenLimit` sonra `failed` olur;
///   bitişi bilinen son etkinlik anıdır.
enum SessionMerger {
    static let msbuildGap: TimeInterval = 2
    static let msbuildOpenLimit: TimeInterval = 15 * 60

    static func sessions(from raw: [BuildSession], now: Date) -> [BuildSession] {
        var result: [BuildSession] = []
        var groups: [String: [BuildSession]] = [:]
        var msbuild: [String: [BuildSession]] = [:]

        for s in raw {
            if let group = s.group {
                groups[group, default: []].append(s)
            } else if s.isMSBuild {
                let key = [s.source.rawValue, s.host ?? "", s.solution ?? ""].joined(separator: "|")
                msbuild[key, default: []].append(s)
            } else {
                result.append(s)
            }
        }

        for (group, members) in groups {
            result.append(merge(members, id: "group:\(group)", now: now, closesOpen: false))
        }

        for members in msbuild.values {
            let sorted = members.sorted { $0.start < $1.start }
            var cluster: [BuildSession] = []
            var activityEnd = Date.distantPast
            for s in sorted {
                if !cluster.isEmpty && s.start > activityEnd.addingTimeInterval(msbuildGap) {
                    // Yeni bir build başladı; öncekinde açık kalanlar başarısız sayılır.
                    result.append(merge(cluster, id: cluster[0].id, now: now, closesOpen: true))
                    cluster = []
                    activityEnd = .distantPast
                }
                cluster.append(s)
                activityEnd = max(activityEnd, s.end ?? s.start)
            }
            if !cluster.isEmpty {
                result.append(merge(cluster, id: cluster[0].id, now: now, closesOpen: false))
            }
        }
        return result
    }

    /// Kayıtları tek oturumda birleştirir. Wrapper gibi MSBuild dışı bir üye varsa
    /// oturumun türü, bitişi ve durumu ondan gelir.
    private static func merge(_ members: [BuildSession], id: String, now: Date, closesOpen: Bool) -> BuildSession {
        if members.count == 1 && !closesOpen && !(members[0].isMSBuild && members[0].isActive) {
            return members[0]
        }
        let primary = members.first { !$0.isMSBuild }
            ?? members.max { ($0.end ?? $0.start) < ($1.end ?? $1.start) }!
        var merged = BuildSession(
            id: id, source: primary.source, tech: primary.tech, tool: primary.tool,
            group: primary.group, host: primary.host, solution: primary.solution,
            kind: primary.kind, project: primary.project, device: primary.device,
            start: members.map(\.start).min()!, end: nil, status: .running, pid: nil
        )

        if !primary.isMSBuild {
            // Grubu wrapper açtı: bitişi ve sonucu wrapper bilir.
            merged.end = primary.end
            merged.status = primary.status
            merged.pid = primary.pid
            return merged
        }

        let activityEnd = members.map { $0.end ?? $0.start }.max()!
        let hasOpen = members.contains(where: \.isActive)
        if hasOpen && !closesOpen && now.timeIntervalSince(activityEnd) < msbuildOpenLimit {
            return merged // hâlâ derleniyor
        }
        merged.end = activityEnd
        if hasOpen || members.contains(where: { $0.status == .failed }) {
            merged.status = .failed
        } else if members.contains(where: { $0.status == .cancelled }) {
            merged.status = .cancelled
        } else {
            merged.status = .success
        }
        return merged
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
