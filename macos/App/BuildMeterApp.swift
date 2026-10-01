import SwiftUI

@main
struct BuildMeterApp: App {
    @StateObject private var store = EventStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menü bardaki ikon + süre. Build sürerken canlı sayaç gösterir.
struct MenuBarLabel: View {
    @ObservedObject var store: EventStore

    var body: some View {
        let stats = Stats(sessions: store.sessions, now: store.now)
        if let oldest = store.active.min(by: { $0.start < $1.start }) {
            Image(systemName: "hourglass")
            Text(DurationFormat.clock(store.now.timeIntervalSince(oldest.start)))
                .monospacedDigit()
        } else {
            Image("MenuBarIcon")
            Text(DurationFormat.compact(stats.summary(.today).mergedTotal))
        }
    }
}
