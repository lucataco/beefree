import BeeKit
import BeeProtocol
import SwiftData
import SwiftUI

/// The first screen: whether what you're saying is being saved, and the one button that changes it.
/// Everything about the Bee itself is a level down, in Your Bee.
struct HomeView: View {
    @Environment(BeeStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Re-evaluated every couple of seconds: audio that stops arriving doesn't announce itself.
                    TimelineView(.periodic(from: .now, by: 2)) { context in
                        StatusHero(status: CaptureStatus(store, now: context.date))
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 20, trailing: 20))

                Section {
                    NavigationLink {
                        BeeDetailsView()
                    } label: {
                        LabeledContent("Your Bee") {
                            BatteryLabel(percent: store.status.battery, charging: store.status.charging ?? false)
                        }
                    }
                    RecordedToday()
                }
            }
            .navigationTitle(store.known?.name ?? "Bee")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refreshNow() }
        }
    }
}

private struct StatusHero: View {
    @Environment(BeeStore.self) private var store
    var status: CaptureStatus

    var body: some View {
        VStack(spacing: 20) {
            BeeArtwork(light: status.light, live: status.isLive)
                .frame(width: 168, height: 168)
                .opacity(status.isConnected ? 1 : 0.45)
                .animation(.smooth, value: status.isConnected)

            VStack(spacing: 6) {
                Text(status.title)
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(status.isWarning ? Color.orange : Color.primary)
                    .contentTransition(.opacity)
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .animation(.smooth, value: status.title)

            if let action = status.action {
                button(action)
            }

            if let problem = store.captureProblem, status.isConnected {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if case .away = status.kind {
                PairAgainHint()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var detail: some View {
        if case let .recording(since) = status.kind {
            Text("\(status.detail) for \(Text(timerInterval: since...Date.distantFuture, countsDown: false).monospacedDigit())")
        } else {
            Text(status.detail)
        }
    }

    private func button(_ action: CaptureStatus.Action) -> some View {
        Button {
            switch action {
            case .mute: Task { await store.setMuted(true) }
            case .unmute: Task { await store.setMuted(false) }
            case .importKey: store.showKeyImport = true
            }
        } label: {
            HStack(spacing: 8) {
                if store.busy.contains(.mute) {
                    ProgressView()
                } else {
                    Image(systemName: action == .mute ? "mic.slash.fill" : action == .unmute ? "mic.fill" : "key.fill")
                }
                Text(action == .mute ? "Mute" : action == .unmute ? "Unmute" : "Import Audio Key")
            }
            .font(.headline)
            .frame(maxWidth: 260)
            .padding(.vertical, 8)
        }
        .modifier(ActionStyle(prominent: action != .mute))
        .disabled(store.busy.contains(.mute))
    }
}

/// Unmute and the key stand out; Mute, the resting choice, stays quieter.
private struct ActionStyle: ViewModifier {
    var prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent).tint(.honey)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// After a while without the Bee: the likely reasons, and the fix for the one the app can't fix itself.
private struct PairAgainHint: View {
    @Environment(BeeStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: store.linkChanged, by: 5)) { context in
            if context.date.timeIntervalSince(store.linkChanged) > 20 || store.needsRepair {
                VStack(spacing: 10) {
                    Text("If it's on and nearby but won't connect, it may have been paired with another device since. Pair it with this iPhone again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Pair Again") { Task { await store.forget() } }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 12)
            }
        }
    }
}

/// How much audio today has brought in.
private struct RecordedToday: View {
    @Query private var today: [AudioSegment]

    init() {
        let midnight = Calendar.current.startOfDay(for: .now)
        _today = Query(filter: #Predicate<AudioSegment> { $0.start >= midnight })
    }

    var body: some View {
        LabeledContent("Recorded today") {
            Text(Format.duration(today.reduce(0) { $0 + $1.duration })).monospacedDigit()
        }
    }
}

#Preview {
    HomeView().environment(BeeStore(preview: true))
}
