import XCTest

/// `spec/fixtures/` altındaki her vaka için olay dosyalarını okur, oturumları üretir
/// ve `expected.json` içindeki özetle karşılaştırır. Go ve C# uygulamaları da aynı
/// fixture'ları doğrular (bkz. spec/README.md).
final class FixtureTests: XCTestCase {
    private static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos
        .deletingLastPathComponent()   // repo kökü
        .appendingPathComponent("spec/fixtures", isDirectory: true)

    private struct Expected: Decodable {
        struct Window: Decodable { var start: Double; var end: Double }
        struct Session: Decodable, Equatable {
            var project: String
            var tech: String
            var source: String
            var kind: String
            var status: String
            var start: Double
            var end: Double?
        }
        struct Summary: Decodable {
            var count: Int
            var successCount: Int
            var mergedTotal: Double
            var sumTotal: Double
            var byTech: [String: Double]
            var bySource: [String: Double]
            var byProject: [String: Double]
            var byHost: [String: Double]
            var sessions: [Session]
        }
        var now: Double
        var window: Window
        var summary: Summary
    }

    func testFixtures() throws {
        let cases = try FileManager.default.contentsOfDirectory(atPath: Self.fixturesURL.path)
            // output/ gibi expected.json'u olmayan klasörler vaka değildir.
            .filter { FileManager.default.fileExists(atPath: Self.fixturesURL
                .appendingPathComponent($0).appendingPathComponent("expected.json").path) }
            .sorted()
        XCTAssertFalse(cases.isEmpty, "Fixture bulunamadı: \(Self.fixturesURL.path)")
        for name in cases {
            try check(name)
        }
    }

    private func check(_ name: String) throws {
        let dir = Self.fixturesURL.appendingPathComponent(name, isDirectory: true)
        let expected = try JSONDecoder().decode(
            Expected.self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))

        var log = EventLog()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("events") && $0.hasSuffix(".jsonl") }
            .sorted()
        for file in files {
            log.ingest(try Data(contentsOf: dir.appendingPathComponent(file)))
        }

        let now = Date(timeIntervalSince1970: expected.now)
        let window = DateInterval(start: Date(timeIntervalSince1970: expected.window.start),
                                  end: Date(timeIntervalSince1970: expected.window.end))
        let sessions = SessionMerger.sessions(from: Array(log.byID.values), now: now)
        let summary = Stats(sessions: sessions, now: now).summary(for: (.today, window))
        let e = expected.summary

        let actualSessions = sessions
            .filter { window.contains($0.start) }
            .sorted { ($0.start, $0.source.rawValue) < ($1.start, $1.source.rawValue) }
            .map {
                Expected.Session(project: $0.project, tech: $0.tech.rawValue, source: $0.source.rawValue,
                                 kind: $0.kind, status: $0.status.rawValue,
                                 start: $0.start.timeIntervalSince1970, end: $0.end?.timeIntervalSince1970)
            }
        XCTAssertEqual(actualSessions, e.sessions, "\(name): oturumlar")
        XCTAssertEqual(summary.count, e.count, "\(name): count")
        XCTAssertEqual(summary.successCount, e.successCount, "\(name): successCount")
        XCTAssertEqual(summary.mergedTotal, e.mergedTotal, accuracy: 0.001, "\(name): mergedTotal")
        XCTAssertEqual(summary.sumTotal, e.sumTotal, accuracy: 0.001, "\(name): sumTotal")
        XCTAssertEqual(dict(summary.byTech.map { ($0.key.rawValue, $0.value) }), e.byTech, "\(name): byTech")
        XCTAssertEqual(dict(summary.bySource.map { ($0.key.rawValue, $0.value) }), e.bySource, "\(name): bySource")
        XCTAssertEqual(dict(summary.byProject.map { ($0.key, $0.value) }), e.byProject, "\(name): byProject")

        var byHost: [String: Double] = [:]
        for s in summary.sessions {
            guard let host = s.host else { continue }
            byHost[host, default: 0] += s.interval(clippedTo: window, now: now)?.duration ?? 0
        }
        XCTAssertEqual(byHost, e.byHost, "\(name): byHost")
    }

    private func dict(_ pairs: [(String, Double)]) -> [String: Double] {
        Dictionary(pairs, uniquingKeysWith: +)
    }
}
