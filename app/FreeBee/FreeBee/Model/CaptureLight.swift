import ActivityKit
import Foundation

/// Keeps the recording-light Live Activity in step with the capture. iOS only lets an app start a Live
/// Activity from the foreground, so one starts when you unmute in the app (or open it while listening);
/// after that the app updates it from the background as the link comes and goes, and ends it on mute.
final class CaptureLight {
    private var activity: Activity<CaptureActivityAttributes>?
    private var state: CaptureActivityAttributes.ContentState?

    init() {
        // Adopt one left running by a previous launch.
        activity = Activity<CaptureActivityAttributes>.activities.first
        state = activity?.content.state
    }

    func update(listening: Bool, capturing: Bool, connected: Bool, name: String, foreground: Bool) {
        guard listening else {
            end()
            return
        }
        let phase: CaptureActivityAttributes.ContentState.Phase = capturing ? .capturing : connected ? .waiting : .disconnected
        let since = phase == .capturing && state?.phase == .capturing ? state?.since ?? .now : .now
        let next = CaptureActivityAttributes.ContentState(phase: phase, since: since)
        if let activity, activity.activityState == .active {
            guard next.phase != state?.phase else { return }
            state = next
            Task { await activity.update(ActivityContent(state: next, staleDate: nil)) }
        } else if foreground, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(
                    attributes: CaptureActivityAttributes(name: name),
                    content: ActivityContent(state: next, staleDate: nil)
                )
                state = next
            } catch {
                activity = nil
            }
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
