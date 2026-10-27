import BeeProtocol
import Foundation

/// Read-only MCUmgr queries over the SMP characteristic, as in `beekit fw`.
@MainActor
public final class SMPClient {
    public static let defaultTimeout: Duration = .seconds(5)

    private struct Key: Equatable {
        let group: UInt16
        let sequence: UInt8
        let command: UInt8
    }

    private struct Waiting {
        let key: Key
        let continuation: CheckedContinuation<SMP.Frame, Error>
        var timer: Task<Void, Never>?
    }

    private let transport: any BeeTransport
    private let gate = SerialGate()
    private var reassembler = SMP.Reassembler()
    private var waiting: Waiting?
    private var sequence: UInt8 = 0

    public init(transport: any BeeTransport) {
        self.transport = transport
        transport.smpHandler = { [weak self] data in self?.receive(data) }
    }

    public func start() async throws {
        reassembler.reset()
        try await transport.setSMPNotifications(true)
    }

    public func stop() async {
        try? await transport.setSMPNotifications(false)
        transport.smpHandler = nil
    }

    /// Sends an op-0 (read) request and returns the decoded CBOR reply.
    public func read(group: UInt16, command: UInt8, body: CBOR = [:], timeout: Duration = defaultTimeout) async throws -> CBOR {
        await gate.enter()
        defer { gate.leave() }

        sequence &+= 1
        let key = Key(group: group, sequence: sequence, command: command)
        let request = SMP.readRequest(group: group, command: command, sequence: sequence, body: body)
        let frame = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SMP.Frame, Error>) in
            waiting = Waiting(key: key, continuation: continuation)
            waiting?.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(key, with: .failure(BeeError.smpTimeout))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.writeSMP(request)
                } catch {
                    self.finish(key, with: .failure(error))
                }
            }
        }
        let body = try frame.decodedBody()
        try SMP.check(body)
        return body
    }

    private func receive(_ data: Data) {
        for frame in reassembler.append(data) {
            let key = Key(group: frame.header.group, sequence: frame.header.sequence, command: frame.header.command)
            finish(key, with: .success(frame))
        }
    }

    private func finish(_ key: Key, with result: Result<SMP.Frame, Error>) {
        guard let current = waiting, current.key == key else { return }
        waiting = nil
        current.timer?.cancel()
        current.continuation.resume(with: result)
    }

    // MARK: queries

    public func imageState() async throws -> [ImageSlot] {
        ImageSlot.parseImageState(try await read(group: SMP.Group.image, command: SMP.ImageCommand.state))
    }

    public func bootloader() async throws -> String? {
        try await read(group: SMP.Group.os, command: SMP.OSCommand.bootloaderInfo)["bootloader"]?.string
    }

    public func parameters() async throws -> SMPParameters {
        SMPParameters(try await read(group: SMP.Group.os, command: SMP.OSCommand.mcumgrParams))
    }

    public func appInfo() async throws -> String {
        try await read(group: SMP.Group.os, command: SMP.OSCommand.appInfo, body: ["format": "a"])["output"]?.string ?? ""
    }

    /// Everything the firmware screen shows. Each query fails on its own (ours answers ENOTSUP for app info).
    public func report() async -> FirmwareReport {
        FirmwareReport(
            slots: await lookup { try await self.imageState() },
            bootloader: await lookup { try await self.bootloader() ?? "?" },
            parameters: await lookup { try await self.parameters() },
            appInfo: await lookup { try await self.appInfo() }
        )
    }

    private func lookup<T: Sendable>(_ query: () async throws -> T) async -> Lookup<T> {
        do {
            return .value(try await query())
        } catch let error as SMP.ResponseError where error.isNotSupported {
            return .unsupported
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

public enum Lookup<Value: Sendable>: Sendable {
    case value(Value)
    case unsupported
    case failed(String)

    public var value: Value? { if case let .value(v) = self { v } else { nil } }
}

public struct FirmwareReport: Sendable {
    public var slots: Lookup<[ImageSlot]>
    public var bootloader: Lookup<String>
    public var parameters: Lookup<SMPParameters>
    public var appInfo: Lookup<String>

    public init(slots: Lookup<[ImageSlot]>, bootloader: Lookup<String>, parameters: Lookup<SMPParameters>, appInfo: Lookup<String>) {
        self.slots = slots
        self.bootloader = bootloader
        self.parameters = parameters
        self.appInfo = appInfo
    }

    /// The slot the Bee is running, if image state answered.
    public var activeSlot: ImageSlot? { slots.value?.first { $0.active } }
    /// The other bootable slot (ours keeps 0.5.0 there).
    public var backupSlot: ImageSlot? { slots.value?.first { !$0.active } }
}
