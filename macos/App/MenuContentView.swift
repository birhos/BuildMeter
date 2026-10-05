import Charts
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var store: EventStore
    @State private var reportRange: ReportRange = .today
    @State private var copied = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var techFilter: BuildTech?

    private var stats: Stats { Stats(sessions: store.sessions, now: store.now, tech: techFilter) }

    /// Kayıtlarda görülen teknolojiler; birden fazlaysa filtre gösterilir.
    private var knownTechs: [BuildTech] {
        let seen = Set(store.sessions.map(\.tech))
        return BuildTech.allCases.filter(seen.contains)
    }

    var body: some View {
        let today = stats.summary(.today)
        VStack(alignment: .leading, spacing: 14) {
            header
            if !store.active.isEmpty { activeSection }
            todaySection(today)
            if techFilter == nil && today.byTech.count > 1 { techSection(today) }
            if !today.bySource.isEmpty { sourceSection(today) }
            weekChart
            if !today.byProject.isEmpty { projectSection(today) }
            recentSection
            Divider()
            reportSection
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Bölümler

    private var header: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("BuildMeter").font(.headline)
            Spacer()
            if knownTechs.count > 1 || techFilter != nil {
                Picker("", selection: $techFilter) {
                    Text("Tümü").tag(BuildTech?.none)
                    ForEach(knownTechs, id: \.self) { Text($0.title).tag(BuildTech?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Menu {
                Toggle("Girişte başlat", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Button("Veri klasörünü aç") {
                    NSWorkspace.shared.open(EventStore.dataDirectory)
                }
                Button("Verileri yeniden yükle") { store.reloadAll() }
                Divider()
                Button("Çıkış") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Şu an derleniyor")
            ForEach(store.active.filter { techFilter == nil || $0.tech == techFilter }) { s in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Image(systemName: s.source.symbol).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.project).font(.callout.weight(.medium))
                        Text([s.tech.title, s.source.title, s.device].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(DurationFormat.clock(s.duration(now: store.now)))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func todaySection(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Bugün beklenen süre")
            Text(DurationFormat.long(s.mergedTotal))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 14) {
                stat("Build", "\(s.count)")
                stat("Başarılı", "\(s.successCount)")
                stat("Ortalama", s.count > 0 ? DurationFormat.long(s.average) : "–")
                stat("En uzun", s.count > 0 ? DurationFormat.long(s.longest) : "–")
            }
        }
    }

    private func techSection(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Teknolojiye göre")
            chips(s.byTech.map { ($0.key.symbol, $0.key.title, $0.value) })
        }
    }

    private func sourceSection(_ s: Summary) -> some View {
        chips(s.bySource.map { ($0.key.symbol, $0.key.title, $0.value) })
    }

    private func chips(_ items: [(symbol: String, title: String, value: TimeInterval)]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipViews(items) }
            VStack(alignment: .leading, spacing: 6) { chipViews(items) }
        }
    }

    private func chipViews(_ items: [(symbol: String, title: String, value: TimeInterval)]) -> some View {
        ForEach(items, id: \.title) { item in
            HStack(spacing: 5) {
                Image(systemName: item.symbol)
                Text(item.title)
                Text(DurationFormat.long(item.value)).fontWeight(.semibold)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
    }

    private var weekChart: some View {
        let days = stats.dailyTotals(days: 7)
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Son 7 gün")
            Chart(days, id: \.day) { item in
                BarMark(
                    x: .value("Gün", item.day, unit: .day),
                    y: .value("Dakika", item.total / 60)
                )
                .foregroundStyle(Calendar.current.isDateInToday(item.day) ? Color.blue : Color.blue.opacity(0.45))
                .cornerRadius(3)
                .annotation(position: .top) {
                    if item.total >= 60 {
                        Text(DurationFormat.compact(item.total)).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "tr_TR")), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))dk") } }
                }
            }
            .frame(height: 110)
        }
    }

    private func projectSection(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Projeler (bugün)")
            let maxValue = s.byProject.first?.value ?? 1
            ForEach(s.byProject.prefix(5), id: \.key) { item in
                HStack {
                    Text(item.key).font(.callout).lineLimit(1)
                    Spacer()
                    Text(DurationFormat.long(item.value)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.blue.opacity(0.12))
                            .frame(width: geo.size.width * item.value / max(maxValue, 1))
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        let recent = stats.sessions.filter { !$0.isActive }.prefix(6)
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Son build'ler")
            if recent.isEmpty {
                Text("Henüz kayıt yok. Terminalden `flutter run`, `dotnet build` ya da `npm run dev` çalıştırın veya editörden debug başlatın.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(recent)) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.status.symbol)
                        .foregroundStyle(s.status == .success ? .green : (s.status == .failed ? .red : .secondary))
                        .help(s.status.title)
                    Image(systemName: s.source.symbol).foregroundStyle(.secondary).frame(width: 16)
                        .help(s.source.title)
                    Text(s.project).lineLimit(1)
                        .help(s.tech.title)
                    if s.kind != "run" {
                        Text(s.kind).font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(s.start, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                    Text(DurationFormat.long(s.duration(now: store.now)))
                        .monospacedDigit()
                        .frame(width: 78, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }

    private var reportSection: some View {
        HStack {
            Picker("", selection: $reportRange) {
                ForEach(ReportRange.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Spacer()
            Button {
                ReportBuilder.copyText(stats: stats, range: reportRange)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Kopyalandı" : "Raporu kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button {
                ReportBuilder.exportCSV(stats: stats, range: reportRange)
            } label: {
                Label("CSV", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: - Yardımcılar

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased(with: Locale(identifier: "tr_TR")))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
