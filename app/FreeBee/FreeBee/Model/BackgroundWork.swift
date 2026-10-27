import BackgroundTasks
import Foundation
import MetricKit

/// Runs the processor when the app isn't in front.
///
/// - Overnight: a `BGProcessingTask` that requires external power, which also turns off the CPU monitor
///   that otherwise kills background work at about 80% CPU over 60 s. iOS usually runs it overnight on the
///   charger. The Bee going on its own charger is the hint that the day is over, so that schedules it too.
/// - "Process now": a `BGContinuedProcessingTask`, which starts at once and keeps going (with a system
///   progress indicator) if you leave the app.
enum BackgroundWork {
    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.example.FreeBee" }
    static var nightlyIdentifier: String { "\(bundleID).nightly" }
    private static var continuedPrefix: String { "\(bundleID).process" }

    /// Must run before the app finishes launching.
    static func register(_ store: BeeStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyIdentifier, using: .main) { task in
            MainActor.assumeIsolated {
                runNightly(task, store: store)
            }
        }
    }

    static func scheduleNightly() {
        let request = BGProcessingTaskRequest(identifier: nightlyIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        Task {
            // Fails in the simulator and with Background App Refresh off; the foreground still works.
            try? await BGTaskScheduler.shared.submitTaskRequest(request)
        }
    }

    /// Starts processing as a continued task. Returns false if the system wouldn't take one (the
    /// simulator, an older device), in which case the caller runs it in the foreground.
    static func processNow(_ store: BeeStore) async -> Bool {
        // Info.plist permits the wildcard; each request registers its own identifier under it, at any
        // time (continued tasks are exempt from register-at-launch). Registering the "*" itself returned
        // false on iOS 27, so Process Now never got its background task.
        let identifier = "\(continuedPrefix).\(UUID().uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated {
                runContinued(task, store: store)
            }
        }
        guard registered else {
            store.log(.other, "Couldn't register a background task for processing; processing in the app")
            return false
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Processing conversations",
            subtitle: "Starting…"
        )
        request.strategy = .fail
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            return true
        } catch {
            store.log(.other, "Couldn't start a background task for processing (\(error.localizedDescription)); processing in the app")
            return false
        }
    }

    private static func runNightly(_ task: BGTask, store: BeeStore) {
        nonisolated(unsafe) let task = task
        let work = Task {
            let finished = await store.processor.process(as: .nightly)
            if !store.processor.backlog.isEmpty { scheduleNightly() }
            task.setTaskCompleted(success: finished)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in store.processor.cancel() }
        }
    }

    private static func runContinued(_ task: BGTask, store: BeeStore) {
        let run = ContinuedRun(task: task)
        Task {
            let finished = await store.processor.process(as: .continued) { run.report($0) }
            run.finish(finished)
        }
        task.expirationHandler = {
            Task { @MainActor in
                run.finish(false)
                if store.isActive {
                    // Still on screen: carry on as an in-app run, which stops if the app is left.
                    store.processor.keepRunningInApp()
                    store.log(.other, "iOS ended Process Now's background time; carrying on in the app")
                } else {
                    store.processor.cancel()
                    store.log(.other, "iOS ended Process Now's background time; it picks up tonight on the charger")
                    scheduleNightly()
                }
            }
        }
    }
}

/// One "Process Now" continued task: the progress the system shows, and completion exactly once.
///
/// iOS expires a continued task that appears stalled, and a single step (loading Parakeet, transcribing
/// a long conversation) can run for minutes. So each step gets many units, and a heartbeat creeps
/// through the current step's share while it runs, slowing down as it nears the end and never passing it.
private final class ContinuedRun {
    private static let unitsPerStep: Int64 = 10_000
    private let task: BGTask
    private var stepEnd: Int64 = 0
    private var finished = false
    private var heartbeat: Task<Void, Never>?

    init(task: BGTask) {
        self.task = task
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let progress = self.progress else { return }
                let room = self.stepEnd - 1 - progress.completedUnitCount
                if room > 0 { progress.completedUnitCount += max(1, room / 50) }
            }
        }
    }

    private var continued: BGContinuedProcessingTask? { task as? BGContinuedProcessingTask }
    private var progress: Foundation.Progress? { finished ? nil : continued?.progress }

    func report(_ step: Processor.Progress) {
        guard let progress else { return }
        progress.totalUnitCount = Int64(step.total) * Self.unitsPerStep
        progress.completedUnitCount = Int64(step.done) * Self.unitsPerStep
        stepEnd = Int64(step.done + 1) * Self.unitsPerStep
        continued?.updateTitle("Processing conversations", subtitle: "\(step.step) · \(step.done + 1) of \(step.total)")
    }

    func finish(_ success: Bool) {
        guard !finished else { return }
        if success, let progress { progress.completedUnitCount = progress.totalUnitCount }
        finished = true
        heartbeat?.cancel()
        task.setTaskCompleted(success: success)
    }
}

/// MetricKit's daily reports, kept on the device (Library/Diagnostics) and summarized in the event log.
/// Background terminations are the number that says whether all-day capture holds up.
enum Diagnostics {
    nonisolated static let folder: URL = {
        let url = URL.applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated private static let manager = MetricManager()

    static func start(log: @escaping @MainActor (String) -> Void) {
        Task.detached(priority: .background) {
            for await report in manager.metricReports {
                let name = "metrics-\(Int(report.timeRange.end.timeIntervalSince1970)).json"
                if let data = try? JSONEncoder().encode(report) { try? data.write(to: folder.appendingPathComponent(name)) }
                let line = summary(of: report)
                await log(line)
            }
        }
        Task.detached(priority: .background) {
            for await report in manager.diagnosticReports {
                let name = "diagnostic-\(Int(Date.now.timeIntervalSince1970)).json"
                if let data = try? JSONEncoder().encode(report) { try? data.write(to: folder.appendingPathComponent(name)) }
                await log("MetricKit diagnostic saved (\(name))")
            }
        }
    }

    nonisolated private static func summary(of report: MetricReport) -> String {
        var terminations: [String: Int] = [:]
        var measured = false
        for entry in report.intervalEntries {
            for value in entry.values {
                guard case let .backgroundTermination(metric) = value else { continue }
                measured = true
                terminations["memory", default: 0] += metric.memoryLimitTerminationCount
                terminations["CPU", default: 0] += metric.highCPUTerminationCount
                terminations["pressure", default: 0] += metric.systemPressureTerminationCount
                terminations["watchdog", default: 0] += metric.watchdogTerminationCount
                terminations["timeout", default: 0] += metric.taskTimeoutTerminationCount
            }
        }
        let range = report.timeRange.start.formatted(date: .abbreviated, time: .omitted)
        let killed = terminations.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        // A report can leave the metric out (a day the app barely ran in the background): that isn't zero.
        guard measured else { return "MetricKit (\(range)): no background termination data" }
        return "MetricKit (\(range)): " + (killed.isEmpty ? "no background terminations" : "background terminations: " + killed.joined(separator: ", "))
    }
}
