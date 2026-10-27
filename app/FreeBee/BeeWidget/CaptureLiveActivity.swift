import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording light on the Lock Screen and in the Dynamic Island.
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: symbol(context.state.phase))
                    .font(.title2)
                    .foregroundStyle(color(context.state.phase))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(context.state.phase, name: context.attributes.name))
                        .font(.headline)
                    if context.state.phase == .capturing {
                        Text(timerInterval: context.state.since...Date.distantFuture, countsDown: false)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(detail(context.state.phase))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(intent: MuteFromActivityIntent()) {
                    Label("Mute", systemImage: "mic.slash.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(.red)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.35))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.name, systemImage: symbol(context.state.phase))
                        .foregroundStyle(color(context.state.phase))
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.phase == .capturing {
                        Text(timerInterval: context.state.since...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .frame(maxWidth: 70)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(title(context.state.phase, name: context.attributes.name))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(intent: MuteFromActivityIntent()) {
                            Label("Mute", systemImage: "mic.slash.fill")
                        }
                        .tint(.red)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(context.state.phase))
                    .foregroundStyle(color(context.state.phase))
            } compactTrailing: {
                if context.state.phase == .capturing {
                    Text(timerInterval: context.state.since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                }
            } minimal: {
                Image(systemName: symbol(context.state.phase))
                    .foregroundStyle(color(context.state.phase))
            }
            .keylineTint(color(context.state.phase))
        }
    }

    private func symbol(_ phase: CaptureActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .capturing: "waveform"
        case .waiting: "waveform.badge.magnifyingglass"
        case .disconnected: "waveform.slash"
        }
    }

    private func color(_ phase: CaptureActivityAttributes.ContentState.Phase) -> Color {
        // Green like the Bee's own light while it records.
        phase == .capturing ? .green : .secondary
    }

    private func title(_ phase: CaptureActivityAttributes.ContentState.Phase, name: String) -> String {
        switch phase {
        case .capturing: "\(name) is recording"
        case .waiting: "\(name) is set to listen"
        case .disconnected: "\(name) isn't connected"
        }
    }

    private func detail(_ phase: CaptureActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .capturing: ""
        case .waiting: "Waiting for audio"
        case .disconnected: "Nothing is being recorded"
        }
    }
}
