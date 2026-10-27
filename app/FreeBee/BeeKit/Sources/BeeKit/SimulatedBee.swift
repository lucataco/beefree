import BeeProtocol
import Foundation

/// A pretend Bee that answers like ours (legacy hardware, firmware 0.6.1).
/// Used for demo mode, SwiftUI previews, the simulator and tests.
@MainActor
public final class SimulatedBee: BeeTransport {
    public var controlHandler: ((Data) -> Void)?
    public var smpHandler: ((Data) -> Void)?
    public var audioHandler: ((Data) -> Void)?
    /// Called after a power-off command, when a real Bee would drop the link.
    public var onDisconnect: (() -> Void)?

    public var latency: Duration
    public var battery = 82
    public var charging = false
    public var brightness = 60
    public var state: DeviceState = .recording
    public var codec: Codec = .aac
    public var firmware = FirmwareVersion(major: 0, minor: 6, patch: 1)
    public var txLevel = 8
    public var bitrate = 32000
    public var rssi = -58
    public private(set) var sessionOpen = false
    /// Every command the simulator received, in order.
    public private(set) var received: [Command] = []

    public let deviceIDBytes: Data
    public var deviceID: String { (try? DeviceID.format(deviceIDBytes)) ?? "" }

    /// A token this simulator accepts: SKV1 + its id + a zero key + a zero trailer.
    public var demoToken: SealedToken {
        // swiftlint:disable:next force_try
        try! SealedToken(raw: SealedToken.magic + deviceIDBytes + Data(count: 16) + Data(count: 80))
    }

    /// What the demo Bee "hears": ADTS frames, looped. Defaults to random frames (valid headers, noise
    /// payloads); the app swaps in real AAC so the demo can be transcribed.
    public var audioClip: [Data] = SimulatedBee.placeholderClip
    /// Looped after `audioClip` has played once, if set (a real Bee streams silence when nobody talks).
    public var audioSilence: [Data] = []
    /// Notification size: 495 bytes, like our Bee at the 498-byte MTU macOS negotiated.
    public var maximumNotificationLength = 495
    public private(set) var audioNotifying = false
    /// Packets sent since audio was subscribed.
    public private(set) var audioPacketsSent = 0

    private var ambient: Task<Void, Never>?
    private var streaming: Task<Void, Never>?
    private var audioKey = Data(count: 16)
    private var nonce = Data(count: 12)

    public init(deviceIDBytes: Data = Data([0x3C, 0x5A, 0x11, 0xB7, 0x08, 0xE2, 0x4D, 0x91]), latency: Duration = .milliseconds(60)) {
        self.deviceIDBytes = deviceIDBytes
        self.latency = latency
    }

    // MARK: transport

    public func writeControl(_ data: Data) async throws {
        try await Task.sleep(for: latency / 2)
        let replies = handle(data)
        deliver(replies, to: \.controlHandler)
    }

    public func writeSMP(_ data: Data) async throws {
        let b = [UInt8](data)
        guard b.count >= SMP.headerLength else { return }
        let group = UInt16(b[4]) << 8 | UInt16(b[5])
        let sequence = b[6]
        let command = b[7]
        guard b[0] == SMP.Op.read else { return }  // like the real thing, we only ever read
        let body: CBOR = switch (group, command) {
        case (SMP.Group.image, SMP.ImageCommand.state):
            ["images": [
                ["slot": 0, "version": .text(firmware.description), "hash": .bytes(Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 7) })),
                 "bootable": true, "pending": false, "confirmed": true, "active": true, "permanent": false],
                ["slot": 1, "version": "0.5.0", "hash": .bytes(Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 13 + 5) })),
                 "bootable": true, "pending": false, "confirmed": false, "active": false, "permanent": false],
            ], "splitStatus": 0]
        case (SMP.Group.os, SMP.OSCommand.bootloaderInfo): ["bootloader": "MCUboot"]
        case (SMP.Group.os, SMP.OSCommand.mcumgrParams): ["buf_size": 2475, "buf_count": 4]
        default: ["rc": 8]
        }
        let payload = CBOREncoder.encode(body)
        let header = SMP.Header(op: SMP.Op.readResponse, length: UInt16(payload.count), group: group, sequence: sequence, command: command)
        let frame = header.bytes + payload
        // Split into MTU-sized notifications so the reassembler gets exercised.
        let chunks = stride(from: 0, to: frame.count, by: 64).map { frame.subdata(in: $0..<min($0 + 64, frame.count)) }
        deliver(chunks, to: \.smpHandler)
    }

    public func setSMPNotifications(_ enabled: Bool) async throws {
        try await Task.sleep(for: latency)
    }

    public func setAudioNotifications(_ enabled: Bool) async throws {
        try await Task.sleep(for: latency)
        audioNotifying = enabled
        updateStreaming()
    }

    public func readRSSI() async throws -> Int {
        try await Task.sleep(for: latency)
        rssi = max(-90, min(-40, rssi + Int.random(in: -3...3)))
        return rssi
    }

    // MARK: things a person would do with the Bee

    public func pressDouble() { emit(.buttonDoublePress, []) }

    public func hold() {
        emit(.buttonHold, [1])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            self.emit(.buttonHold, [0])
        }
    }

    public func setCharging(_ on: Bool) {
        charging = on
        emit(.charging, [on ? 1 : 0])
    }

    public func setBattery(_ percent: Int) {
        battery = max(0, min(100, percent))
        emit(.battery, [UInt8(battery)])
    }

    /// Battery drifts every so often, like a worn Bee.
    public func startAmbientEvents(every interval: Duration = .seconds(90)) {
        ambient?.cancel()
        ambient = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.setBattery(self.battery + (self.charging ? 1 : -1))
            }
        }
    }

    public func stopAmbientEvents() {
        ambient?.cancel()
        ambient = nil
    }

    // MARK: protocol

    private func emit(_ event: EventCode, _ payload: [UInt8]) {
        controlHandler?(Frame.encode(code: event.rawValue, Data(payload)))
    }

    private func status(_ status: ResponseStatus, _ command: UInt16, _ data: [UInt8] = []) -> Data {
        Frame.encode(code: status.rawValue, Data(command.littleEndianBytes + data))
    }

    private func handle(_ frame: Data) -> [Data] {
        let b = [UInt8](frame)
        guard b.count >= 2 else { return [] }
        let code = UInt16(b[0]) | UInt16(b[1]) << 8
        let payload = Array(b.dropFirst(2))
        guard let command = Command(rawValue: code) else { return [status(.unknownMessage, code)] }
        received.append(command)
        let ok = { (data: [UInt8]) in self.status(.ok, code, data) }

        switch command {
        case .getFirmwareVersion:
            return [ok([UInt8(firmware.patch), UInt8(firmware.minor), UInt8(firmware.major)])]
        case .getBattery:
            return [ok([UInt8(battery), charging ? 1 : 0])]
        case .getDeviceState:
            return [ok([state.rawValue, codec.rawValue])]
        case .getDeviceID:
            return [ok(Array(deviceIDBytes))]
        case .getSecureIDs:
            return [ok(Array(deviceIDBytes) + [0])]
        case .getBrightness:
            return [ok([UInt8(brightness)])]
        case .setBrightness:
            guard payload.count == 2, payload[0] == 1, payload[1] <= 100 else { return [status(.invalidParam, code)] }
            brightness = Int(payload[1])
            return [ok([])]
        case .getTxLevel:
            return [ok([UInt8(txLevel)])]
        case .setTxPower:
            guard let power = payload.first else { return [status(.invalidParam, code)] }
            txLevel = Int(Int8(bitPattern: power))
            return [ok([])]
        case .getBitrate:
            return [ok(Int32(bitrate).littleEndianBytes)]
        case .setBitrate:
            guard payload.count == 4 else { return [status(.invalidParam, code)] }
            bitrate = Int(Int32(bitPattern: payload.le32(at: 0)))
            return [ok([])]
        case .getChargingSpeed:
            return [ok([0])]
        case .getDSN:
            return [status(.unknownMessage, code)]  // legacy hardware has no DSN
        case .setEncryptionKey:
            guard let token = try? SealedToken(raw: Data(payload)), token.deviceID == deviceID else {
                return [status(.error, code)]
            }
            defer { sessionOpen = true }
            if !sessionOpen { audioKey = token.key }
            return [status(sessionOpen ? .keyAccepted : .ok, code)]
        case .getSessionNonce:
            nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
            return [ok(Array(nonce))]
        case .setDeviceState:
            guard let raw = payload.first else { return [status(.invalidParam, code)] }
            let target = DeviceState(rawValue: raw)
            if case .unknown = target { return [status(.invalidParam, code)] }
            var replies = [ok([raw])]
            // Mute and recording are acknowledged without a session but don't stick.
            if !target.needsSession || sessionOpen {
                state = target
                replies.append(Frame.encode(code: EventCode.deviceState.rawValue, Data([state.rawValue, codec.rawValue])))
            }
            if target == .powerOff {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    self.sessionOpen = false
                    self.audioNotifying = false
                    self.updateStreaming()
                    self.onDisconnect?()
                }
            }
            updateStreaming()
            return replies
        }
    }

    // MARK: audio

    /// Like the real one: streams only while subscribed, recording and inside a session.
    private func updateStreaming() {
        let shouldStream = audioNotifying && state == .recording && sessionOpen && !audioClip.isEmpty
        if !shouldStream {
            streaming?.cancel()
            streaming = nil
            return
        }
        guard streaming == nil else { return }
        audioPacketsSent = 0
        streaming = Task { @MainActor [weak self] in
            var pending = Data()
            var frameIndex = 0
            var sequence: UInt32 = 0
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                // One 64 ms frame per tick, sent in fixed-size packets as they fill.
                let clip = self.audioClip, silence = self.audioSilence
                pending += frameIndex < clip.count || silence.isEmpty
                    ? clip[frameIndex % clip.count]
                    : silence[(frameIndex - clip.count) % silence.count]
                frameIndex += 1
                let size = self.maximumNotificationLength - 4
                while pending.count >= size {
                    let chunk = pending.prefix(size)
                    pending.removeFirst(size)
                    if let cipher = try? AudioCipher(key: self.audioKey, nonce: self.nonce),
                       let packet = try? cipher.encrypt(Data(chunk), sequence: sequence) {
                        self.audioHandler?(packet)
                        self.audioPacketsSent += 1
                    }
                    sequence &+= 1
                }
                next = next.advanced(by: .milliseconds(64))
                try? await clock.sleep(until: next)
            }
        }
    }

    /// 1.6 s of frames with valid headers and random payloads: enough to exercise capture, not decodable.
    public static let placeholderClip: [Data] = {
        var seed: UInt64 = 0x5EED
        return (0..<25).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let payload = Data((0..<(213 + Int(seed >> 57))).map { i in UInt8(truncatingIfNeeded: (seed >> 13) &+ UInt64(i)) })
            return ADTSHeader.header(payloadLength: payload.count) + payload
        }
    }()

    private func deliver(_ notifications: [Data], to handler: KeyPath<SimulatedBee, ((Data) -> Void)?>) {
        guard !notifications.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: latency / 2)
            for notification in notifications { self[keyPath: handler]?(notification) }
        }
    }
}
