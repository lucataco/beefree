import AVFoundation
import Foundation
import Observation
import SwiftData

/// Plays archived audio from a point in time: tap a transcript line to hear it.
@Observable
final class Playback {
    private(set) var playing: Date?
    private(set) var error: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    /// Plays from `start` until `end` (or the end of that segment).
    func play(from start: Date, to end: Date? = nil, context: ModelContext) {
        stop()
        let segments = (try? context.fetch(FetchDescriptor<AudioSegment>(predicate: #Predicate { $0.start <= start && !$0.audioDeleted }))) ?? []
        guard let segment = segments.filter({ $0.end > start }).max(by: { $0.start < $1.start }) else {
            error = "The audio for this moment isn't on this iPhone anymore."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: segment.url)
            player.currentTime = max(0, start.timeIntervalSince(segment.start) - 0.3)
            player.play()
            self.player = player
            playing = start
            error = nil
            let length = (end ?? segment.end).timeIntervalSince(start) + 0.6
            stopTask = Task {
                try? await Task.sleep(for: .seconds(max(1, length)))
                guard !Task.isCancelled else { return }
                self.stop()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playing = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
