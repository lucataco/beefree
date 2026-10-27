import BeeProtocol
import Foundation

/// Request/response routing on the control characteristic, the same design as beekit's `device.py`.
///
/// One request is in flight at a time. A status response is matched by its echoed command id
/// (or accepted if it carries none); events go to `onEvent`; anything else lands in `unmatched`.
@MainActor
public final class ControlChannel {
    public typealias Writer = @MainActor (Data) async throws -> Void

    public static let defaultTimeout: Duration = .seconds(5)

    public var onEvent: ((Message) -> Void)?
    /// Recent responses that matched no request, for debugging.
    public private(set) var unmatched: [Message] = []

    private struct Pending {
        let token: Int
        let command: Command
        let continuation: CheckedContinuation<Message, Error>
        var timer: Task<Void, Never>?
    }

    private let writer: Writer
    private let gate = SerialGate()
    private var pending: Pending?
    private var nextToken = 0
    private var closedError: BeeError?

    public init(writer: @escaping Writer) {
        self.writer = writer
    }

    /// Feed every control-characteristic notification here.
    public func receive(_ data: Data) {
        guard let message = try? Frame.decode(data) else { return }
        if message.isEvent {
            onEvent?(message)
            return
        }
        if let pending, message.command == nil || message.command == pending.command.rawValue {
            finish(pending.token, with: .success(message))
        } else {
            unmatched.append(message)
            if unmatched.count > 32 { unmatched.removeFirst() }
        }
    }

    /// Sends a command and returns the response data. Throws `BeeError.rejected` for non-OK statuses.
    public func request(_ command: Command, _ payload: Data = Data(), timeout: Duration = defaultTimeout) async throws -> Data {
        await gate.enter()
        defer { gate.leave() }
        if let closedError { throw closedError }

        nextToken &+= 1
        let token = nextToken
        let frame = Frame.encode(command, payload)
        let message = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message, Error>) in
            pending = Pending(token: token, command: command, continuation: continuation)
            pending?.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(token, with: .failure(BeeError.timeout(command)))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.writer(frame)
                } catch {
                    self.finish(token, with: .failure(error))
                }
            }
        }
        guard message.ok else { throw BeeError.rejected(command, message) }
        return message.payload
    }

    /// Fails the request in flight and every later one. Call when the link drops.
    public func close(_ error: BeeError = .disconnected) {
        closedError = error
        if let pending { finish(pending.token, with: .failure(error)) }
    }

    private func finish(_ token: Int, with result: Result<Message, Error>) {
        guard let current = pending, current.token == token else { return }
        pending = nil
        current.timer?.cancel()
        current.continuation.resume(with: result)
    }
}
