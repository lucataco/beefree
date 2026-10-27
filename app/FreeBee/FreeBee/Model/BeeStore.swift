import AccessorySetupKit
import BeeKit
import BeePipeline
import BeeProtocol
import CoreBluetooth
import Foundation
import Observation
import SwiftData
import UIKit
import WidgetKit

/// Owns the connection to the Bee and everything the screens show.
///
/// Flow: pair (AccessorySetupKit picker, or a CoreBluetooth scan in the fallback build) → remember the
/// peripheral → keep a connection request pending forever, so iOS reconnects whenever the Bee is back,
/// even with the app in the background → on connect, discover characteristics and read status → keep
/// it current from events → with the audio key, open the session, subscribe to audio and archive it.
@Observable
final class BeeStore {
    static let shared = BeeStore()

    enum PairingMethod {
        case accessorySetup
        case coreBluetooth
    }

    /// Chosen by the build's Info.plist (`BEE_PAIRING`): the two can't be mixed in one app.
    let pairingMethod: PairingMethod =
        Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") != nil ? .accessorySetup : .coreBluetooth

    private(set) var known: KnownBee?
    private(set) var link: LinkState = .unpaired
    private(set) var linkChanged = Date()
    private(set) var status = BeeStatus()
    private(set) var rssi: Int?
    /// SetEncryptionKey succeeded on this connection, so mute and recording stick.
    private(set) var sessionOpen = false
    private(set) var busy: Set<Operation> = []
    private(set) var discoveries: [BeeDiscovery] = []
    private(set) var isScanning = false
    private(set) var isPairing = false
    private(set) var firmware: FirmwareReport?
    /// The Bee refuses this iPhone's bond, typically because it paired with another device since.
    private(set) var needsRepair = false
    /// Device ids with a token in the Keychain, and each token's key fingerprint.
    private(set) var storedKeys: [String: String] = [:]
    var alert: StoreAlert?
    var showKeyImport = false
    /// The scene is in the foreground. Signal strength is only polled then.
    var isActive = true {
        didSet {
            if isActive && !oldValue { foregrounded() }
            if !isActive && oldValue { backgrounded() }
            if isActive { refreshLight() }
            markActive(force: true)
        }
    }

    /// The Bee is set to listen: unmuted here or with its button. Follows the Bee's reported state.
    private(set) var captureWanted = UserDefaults.standard.bool(forKey: BeeStore.captureWantedKey) {
        didSet {
            if persists { UserDefaults.standard.set(captureWanted, forKey: BeeStore.captureWantedKey) }
            refreshLight()
        }
    }
    /// This connection's audio path.
    private(set) var capture = AudioCapture.Status()
    /// When the current stretch of verified audio began; nil while nothing is being saved.
    private(set) var capturingSince: Date?
    /// Something is wrong with the audio (it doesn't decrypt, writes fail).
    private(set) var captureProblem: String?
    let processor: Processor

    var isDemo: Bool { known?.isDemo == true }
    /// The pretend Bee in demo mode. It outlives its connections, so powering it off and on keeps its state.
    private(set) var simulator: SimulatedBee?
    var hasKeyForThisBee: Bool { status.deviceID.map { storedKeys[$0] != nil } ?? false }

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored private let log: EventLog
    @ObservationIgnored let alerts = Alerts()
    @ObservationIgnored private var central: BeeCentral?
    @ObservationIgnored private var accessories: AccessoryPairing?
    @ObservationIgnored private var addedAccessory: ASAccessory?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var transport: (any BeeTransport)?
    @ObservationIgnored private var client: BeeClient?
    @ObservationIgnored private var rssiTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var expectingDisconnect = false
    @ObservationIgnored private var setupFailures = 0
    @ObservationIgnored private var lastSnapshot: BeeSnapshot?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored let recorder = AudioRecorder(directory: Library.recordings)
    @ObservationIgnored private var audio: AudioCapture!
    @ObservationIgnored private var sessionNonce: Data?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var stallRearms = 0
    @ObservationIgnored private var segmentRows: [UUID: AudioSegment] = [:]
    @ObservationIgnored private var lastSegmentSave = Date.distantPast
    @ObservationIgnored private let light = CaptureLight()
    /// A state change the app asked for, until the Bee confirms it: says who it was in the log.
    @ObservationIgnored private var stateRequest: (target: DeviceState, source: StateSource)?
    /// Connection attempts that failed since the Bee was last connected.
    @ObservationIgnored private var failedTries: (count: Int, first: Date, last: Date, reason: String)?
    @ObservationIgnored private var restoredByBluetooth = false
    @ObservationIgnored private var lastActiveWrite = Date.distantPast
    /// Previews don't touch the saved device or the demo flag.
    @ObservationIgnored private let persists: Bool

    init(preview: Bool = false) {
        persists = !preview
        let configuration = ModelConfiguration(isStoredInMemoryOnly: preview)
        do {
            container = try ModelContainer(for: Schema(Library.models), configurations: configuration)
        } catch {
            fatalError("Couldn't open the event log: \(error)")
        }
        log = EventLog(context: container.mainContext)
        processor = Processor(context: container.mainContext)
        audio = AudioCapture(recorder: recorder)
        setUpCapture()
        if preview || UserDefaults.standard.bool(forKey: BeeStore.demoKey) {
            startDemo()
        } else {
            known = KnownBee.load()
            startBluetooth()
        }
        refreshKeys()
        if persists { noteLaunch() }
        #if DEBUG
        processNowIfAsked()
        #endif
    }

    private static let demoKey = "demo"
    private static let captureWantedKey = "captureWanted"
    private static let lastActiveKey = "lastActive"

    /// Who switched the Bee between states, for the event log. Changes nobody here asked for are the Bee's
    /// own: almost always its button.
    enum StateSource: String {
        case app = "in the app"
        case lockScreen = "from the Lock Screen"
        case shortcut = "from Shortcuts or Siri"
        case test = "by the capture test"
    }

    // MARK: - pairing

    /// AccessorySetupKit: shows the system picker. The Bee must be in pairing mode.
    func pair() {
        guard let accessories else { return }
        isPairing = true
        accessories.showPicker { [weak self] error in
            guard let self, let error else { return }
            self.isPairing = false
            self.alert = StoreAlert("Couldn't show the pairing sheet", error: error)
        }
    }

    /// CoreBluetooth fallback: scan for Bees advertising nearby.
    func startScan() {
        discoveries = []
        central?.startScan()
        isScanning = central?.isScanning ?? false
    }

    func stopScan() {
        central?.stopScan()
        isScanning = false
    }

    func choose(_ discovery: BeeDiscovery) {
        stopScan()
        setKnown(KnownBee(
            peripheralID: discovery.id,
            name: discovery.name ?? "Bee",
            deviceID: discovery.advertisement?.deviceID,
            hardware: discovery.advertisement?.hardware,
            viaAccessorySetup: false
        ))
        peripheral = discovery.peripheral
        log.note(.connection, "Paired with \(known?.name ?? "Bee")")
        connectKnown()
    }

    /// Disconnects and forgets the Bee. With AccessorySetupKit this also removes the app's access to it.
    func forget() async {
        guard let known else { return }
        expectingDisconnect = true
        reconnectTask?.cancel()
        if let peripheral { central?.cancel(peripheral) }
        teardownSession()
        simulator?.stopAmbientEvents()
        simulator = nil
        log.note(.connection, "Forgot \(known.name)", deviceID: known.deviceID)
        // Clear first: removing the accessory also sends an accessoryRemoved event.
        let accessory = known.viaAccessorySetup ? accessories?.accessory(for: known.peripheralID) : nil
        clearKnown()
        if let accessory {
            do {
                try await accessories?.remove(accessory)
            } catch {
                alert = StoreAlert("Couldn't remove the accessory", error: error)
            }
        }
    }

    // MARK: - demo

    /// A simulated Bee, for trying the app without one (and for the simulator, which has no Bluetooth).
    func startDemo() {
        let simulator = SimulatedBee()
        simulator.onDisconnect = { [weak self] in self?.simulatorPoweredOff() }
        self.simulator = simulator
        // A spoken conversation instead of noise, so the demo has something to transcribe.
        Task {
            let frames = await DemoAudio.frames()
            if !frames.isEmpty {
                simulator.audioClip = frames
                simulator.audioSilence = DemoAudio.silence()
            }
        }
        setKnown(KnownBee(
            peripheralID: UUID(), name: "Demo Bee", deviceID: simulator.deviceID, hardware: .legacy,
            viaAccessorySetup: false, isDemo: true
        ))
        refreshKeys()
        attachSimulator(simulator)
    }

    private func attachSimulator(_ simulator: SimulatedBee) {
        transport = simulator
        setLink(.connecting)
        Task {
            do {
                try await attach(simulator)
                simulator.startAmbientEvents()
            } catch {
                alert = StoreAlert("Demo failed", error: error)
            }
        }
    }

    private func simulatorPoweredOff() {
        guard let simulator else { return }
        simulator.stopAmbientEvents()
        log.note(.connection, "Powered off", deviceID: status.deviceID)
        expectingDisconnect = false
        teardownSession()
        setLink(.searching)
        // A real Bee waits for its button; the demo one comes back by itself.
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, self.isDemo else { return }
            simulator.state = .mute
            self.attachSimulator(simulator)
        }
    }

    // MARK: - controls

    func setMuted(_ muted: Bool, from source: StateSource = .app) async {
        await perform(.mute, "Couldn't change the microphone") {
            do {
                try await self.applyMute(muted, from: source)
            } catch is MissingKeyError {
                // Not an error to report: the import screen explains what's needed.
                self.showKeyImport = true
            }
        }
    }

    func sleep(_ state: DeviceState) async {
        await perform(.sleep, "Couldn't put the Bee to sleep") {
            let client = try self.connectedClient()
            _ = try await self.request(state, from: .app, on: client)
            self.captureWanted = false
            self.statusChanged()
        }
    }

    func powerOff() async {
        await perform(.power, "Couldn't turn the Bee off") {
            let client = try self.connectedClient()
            self.expectingDisconnect = true
            // It may announce the change before dropping the link, and never answer.
            self.stateRequest = (.powerOff, .app)
            defer { self.stateRequest = nil }
            do {
                try await client.setState(.powerOff)
                self.status.state = .powerOff
            } catch let error as BeeError {
                // It may drop the link before it answers.
                switch error {
                case .disconnected, .timeout: return
                default:
                    self.expectingDisconnect = false
                    throw error
                }
            }
        }
    }

    func setBrightness(_ value: Int) async {
        await perform(.brightness, "Couldn't change the brightness") {
            let client = try self.connectedClient()
            try await client.setBrightness(value)
            self.status.brightness = (try? await client.brightness()) ?? value
        }
    }

    func refreshNow() async {
        await perform(.refresh, "Couldn't read the Bee's status") { try await self.refresh() }
    }

    func loadFirmware() async {
        await perform(.firmware, "Couldn't read the firmware details") {
            guard let transport = self.transport, self.link == .ready else { throw BeeError.disconnected }
            let smp = SMPClient(transport: transport)
            try await smp.start()
            let report = await smp.report()
            await smp.stop()
            self.firmware = report
        }
    }

    func loadRadio() async {
        await perform(.radio, "Couldn't read the radio settings") {
            let client = try self.connectedClient()
            self.status.txLevel = try? await client.txLevel()
            self.status.bitrate = try? await client.bitrate()
        }
    }

    func setTxPower(_ power: Int) async {
        await perform(.radio, "Couldn't set the TX power") {
            let client = try self.connectedClient()
            try await client.setTxPower(power)
            self.status.txLevel = try? await client.txLevel()
            self.log.note(.other, "TX power set to \(power)", deviceID: self.status.deviceID)
        }
    }

    func setBitrate(_ bitrate: Int) async {
        await perform(.radio, "Couldn't set the bitrate") {
            let client = try self.connectedClient()
            try await client.setBitrate(bitrate)
            self.status.bitrate = try? await client.bitrate()
            self.log.note(.other, "Bitrate set to \(bitrate)", deviceID: self.status.deviceID)
        }
    }

    func clearLog() {
        log.clear()
    }

    /// Mute (`state 0`) or listen (`state 1`). Both need a session, which needs the captured token.
    private func applyMute(_ muted: Bool, from source: StateSource) async throws {
        let client = try connectedClient()
        guard let deviceID = status.deviceID else { throw StoreError("The Bee hasn't reported its device id yet.") }
        _ = try await ensureSession(client, deviceID: deviceID)
        if !audio.isRunning { await startAudio() }
        let target: DeviceState = muted ? .mute : .recording
        captureWanted = !muted
        let reported = try await request(target, from: source, on: client)
        statusChanged()
        guard reported.state == target else {
            throw StoreError("The Bee acknowledged but is still \(reported.state.title.lowercased()).")
        }
    }

    /// Sets the Bee's state and logs who asked, once: the Bee may announce the change itself (A003)
    /// before the request returns, after it, or not at all.
    private func request(_ target: DeviceState, from source: StateSource, on client: BeeClient) async throws -> DeviceStatus {
        let before = status.state
        stateRequest = (target, source)
        defer { stateRequest = nil }
        try await client.setState(target)
        let reported = try await client.deviceStatus()
        if stateRequest != nil, reported.state != before {
            log.record(.state(reported), deviceID: status.deviceID, source: source.rawValue)
        }
        status.state = reported.state
        status.codec = reported.codec ?? status.codec
        return reported
    }

    private struct MissingKeyError: LocalizedError {
        var errorDescription: String? { "Mute and unmute need this Bee's audio key. Import it from the Mac first." }
    }

    /// SetEncryptionKey with the real token, then GetSessionNonce. Once per connection: the nonce keys
    /// this connection's audio.
    private func ensureSession(_ client: BeeClient, deviceID: String) async throws -> Data {
        if sessionOpen, let sessionNonce { return sessionNonce }
        guard let token = token(for: deviceID) else { throw MissingKeyError() }
        let nonce: Data
        do {
            nonce = try await client.openSession(token)
        } catch let error as BeeError {
            if case .rejected = error {
                throw StoreError("The Bee rejected the saved key. It has to be the token captured when this Bee last paired with the official app.")
            }
            throw error
        }
        sessionOpen = true
        sessionNonce = nonce
        log.note(.connection, "Session opened (key #\(token.fingerprint))", deviceID: deviceID)
        return nonce
    }

    private func connectedClient() throws -> BeeClient {
        guard let client, link == .ready else { throw StoreError("The Bee isn't connected.") }
        return client
    }

    private func perform(_ operation: Operation, _ failure: String, _ body: () async throws -> Void) async {
        busy.insert(operation)
        defer { busy.remove(operation) }
        do {
            try await body()
        } catch {
            alert = StoreAlert(failure, error: error)
        }
    }

    // MARK: - keys

    func token(for deviceID: String) -> SealedToken? {
        if let simulator, simulator.deviceID == deviceID { return simulator.demoToken }
        return KeyStore.token(for: deviceID)
    }

    /// beekit's secrets.json (AirDropped or picked in Files), or a file with the token in hex.
    @discardableResult
    func importKeys(from url: URL) throws -> [KeyFile.Entry] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let entries = try KeyFile.parse(Data(contentsOf: url))
        try save(entries.map(\.token))
        // Files opened from AirDrop are copied into our Inbox. Don't leave the token lying around.
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return entries
    }

    func importKey(hex: String) throws -> SealedToken {
        let token = try KeyFile.parseHex(hex)
        try save([token])
        return token
    }

    func deleteKey(deviceID: String) {
        KeyStore.delete(deviceID: deviceID)
        if deviceID == status.deviceID {
            audio.stop(.stopped)
            sessionOpen = false
            sessionNonce = nil
        }
        refreshKeys()
    }

    /// For `.onOpenURL`: an AirDropped or shared key file.
    func open(_ url: URL) {
        do {
            let entries = try importKeys(from: url)
            let ids = entries.map(\.deviceID).joined(separator: ", ")
            alert = StoreAlert("Key imported", "Saved the audio key for \(ids) in the Keychain.")
        } catch {
            alert = StoreAlert("Couldn't import the key", error: error)
        }
    }

    private func save(_ tokens: [SealedToken]) throws {
        for token in tokens { try KeyStore.save(token) }
        refreshKeys()
        if let id = known?.deviceID, tokens.contains(where: { $0.deviceID == id }) {
            log.note(.connection, "Audio key imported", deviceID: id)
            if link == .ready { Task { await startAudio() } }
        }
    }

    private func refreshKeys() {
        var keys = Dictionary(KeyStore.all().map { ($0.deviceID, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
        if let simulator { keys[simulator.deviceID] = simulator.demoToken.fingerprint }
        storedKeys = keys
    }

    // MARK: - App Intents

    /// Waits for the link, for Shortcuts launched while the app was in the background or not running.
    func waitUntilReady(timeout: Duration = .seconds(20)) async -> Bool {
        if link == .ready { return true }
        guard known != nil else { return false }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.resumeReadyWaiters()
        }
        await withCheckedContinuation { readyWaiters.append($0) }
        timer.cancel()
        return link == .ready
    }

    func setMutedFromIntent(_ muted: Bool, from source: StateSource = .shortcut) async throws {
        guard await waitUntilReady() else { throw StoreError("Your Bee isn't connected.") }
        busy.insert(.mute)
        defer { busy.remove(.mute) }
        try await applyMute(muted, from: source)
    }

    private func resumeReadyWaiters() {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Bluetooth

    private func startBluetooth() {
        guard central == nil else { return }
        makeCentral()
        if pairingMethod == .accessorySetup {
            let accessories = AccessoryPairing()
            accessories.onEvent = { [weak self] event in self?.handle(event) }
            accessories.activate()
            self.accessories = accessories
        }
        setLink(known == nil ? .unpaired : .searching)
    }

    private func makeCentral() {
        // Release the old manager first: two can't share a restore identifier.
        self.central = nil
        let central = BeeCentral(restoreIdentifier: "bee.central")
        central.onEvent = { [weak self] event in self?.handle(event) }
        self.central = central
    }

    private func handle(_ event: AccessoryPairing.Event) {
        switch event {
        case let .activated(list):
            if let known, known.viaAccessorySetup, !list.contains(where: { $0.bluetoothIdentifier == known.peripheralID }) {
                // Removed in Settings › Privacy & Security › Accessories while the app wasn't running.
                log.note(.connection, "\(known.name) was removed from this iPhone's accessories", deviceID: known.deviceID)
                clearKnown()
            } else if known == nil, let accessory = list.first(where: { $0.state == .authorized && $0.bluetoothIdentifier != nil }) {
                // Authorized earlier but the app's own record is gone (for example after a restore).
                adopt(accessory)
            }
        case let .added(accessory):
            addedAccessory = accessory
        case .pickerDismissed:
            isPairing = false
            // Connect only once the picker is gone (connecting while it's up upsets CoreBluetooth).
            if let accessory = addedAccessory {
                addedAccessory = nil
                adopt(accessory)
            }
        case let .removed(accessory):
            if accessory.bluetoothIdentifier == known?.peripheralID, let known {
                log.note(.connection, "\(known.name) was removed from this iPhone's accessories", deviceID: known.deviceID)
                if let peripheral { central?.cancel(peripheral) }
                teardownSession()
                clearKnown()
            }
        case let .setupFailed(error):
            isPairing = false
            addedAccessory = nil
            alert = StoreAlert(
                "Pairing didn't finish",
                (error?.localizedDescription ?? "The Bee didn't complete setup.")
                    + " Press its button 5 times (the light flashes blue-green) and try again."
            )
        }
    }

    private func adopt(_ accessory: ASAccessory) {
        guard let id = accessory.bluetoothIdentifier else { return }
        setKnown(KnownBee(peripheralID: id, name: accessory.displayName, viaAccessorySetup: true))
        peripheral = nil
        log.note(.connection, "Paired with \(accessory.displayName)")
        connectKnown()
        // CoreBluetooth only powers on for apps with an AccessorySetupKit accessory. If it was created
        // before the first one existed and stays off, start it over.
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard self.known?.peripheralID == id, self.central?.state != .poweredOn else { return }
            self.makeCentral()
        }
    }

    private func handle(_ event: BeeCentral.Event) {
        switch event {
        case let .stateChanged(state):
            centralStateChanged(state)
        case let .restored(peripherals):
            // iOS relaunched us in the background for a pending connection or a notification.
            restoredByBluetooth = true
            if let known, let restored = peripherals.first(where: { $0.identifier == known.peripheralID }) {
                peripheral = restored
            }
        case let .discovered(discovery):
            if let index = discoveries.firstIndex(where: { $0.id == discovery.id }) {
                guard discovery.seen.timeIntervalSince(discoveries[index].seen) > 1 else { return }
                discoveries[index] = discovery
            } else {
                discoveries.append(discovery)
            }
        case let .connected(peripheral):
            guard peripheral.identifier == known?.peripheralID else {
                central?.cancel(peripheral)
                return
            }
            self.peripheral = peripheral
            beginSession(peripheral)
        case let .failedToConnect(peripheral, error):
            guard peripheral.identifier == known?.peripheralID else { return }
            // At the edge of range this can repeat every few seconds for minutes. Log the first of each
            // kind; the "Connected" line counts them all.
            let reason = error?.localizedDescription ?? "unknown error"
            if failedTries?.reason != reason {
                log.note(.connection, "Connection failed, retrying: \(reason)", deviceID: known?.deviceID)
            }
            failedTries = ((failedTries?.count ?? 0) + 1, failedTries?.first ?? .now, .now, reason)
            if (error as? CBError)?.code == .peerRemovedPairingInformation { needsRepair = true }
            scheduleReconnect(after: .seconds(needsRepair ? 30 : 3))
        case let .disconnected(peripheral, error):
            disconnected(peripheral, error)
        }
    }

    private func centralStateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if known == nil {
                setLink(.unpaired)
            } else if link != .ready && link != .connecting {
                connectKnown()
            }
        case .unknown:
            break
        default:
            isScanning = false
            if transport is BluetoothTransport { teardownSession() }
            guard known != nil else {
                setLink(.unpaired)
                return
            }
            let reason = switch state {
            case .poweredOff: "Bluetooth is off. Turn it on in Control Center."
            case .unauthorized: "FreeBee doesn't have Bluetooth access. Allow it in Settings."
            case .unsupported: "This device doesn't support Bluetooth LE."
            case .resetting: "Bluetooth is restarting."
            default: "Bluetooth isn't available."
            }
            setLink(.unavailable(reason))
        }
    }

    private func connectKnown() {
        guard let known, !known.isDemo, let central, central.state == .poweredOn, transport == nil else { return }
        reconnectTask?.cancel()
        guard let peripheral = peripheral ?? central.retrievePeripheral(known.peripheralID) else {
            setLink(.searching)
            return
        }
        self.peripheral = peripheral
        switch peripheral.state {
        case .connected:
            beginSession(peripheral)
        case .connecting:
            setLink(.searching)
        default:
            setLink(.searching)
            central.connect(peripheral)
        }
    }

    private func scheduleReconnect(after delay: Duration) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.connectKnown()
        }
    }

    private func beginSession(_ peripheral: CBPeripheral) {
        guard transport == nil else { return }
        let transport = BluetoothTransport(peripheral: peripheral)
        self.transport = transport
        setLink(.connecting)
        Task {
            do {
                try await transport.prepare()
                try await attach(transport)
            } catch {
                guard self.transport === transport else { return }
                setupFailures += 1
                if setupFailures >= 2 { needsRepair = true }
                log.note(.connection, "Setup failed: \(error.localizedDescription)", deviceID: known?.deviceID)
                if setupFailures == 1 && isActive {
                    alert = StoreAlert("Couldn't set up the Bee", error: error)
                }
                // Drop the link; the disconnect handler retries with a backoff.
                central?.cancel(peripheral)
            }
        }
    }

    /// Shared by the real transport and the simulator.
    private func attach(_ transport: any BeeTransport) async throws {
        let client = BeeClient(transport: transport)
        client.hardware = known?.hardware ?? .legacy
        client.onEvent = { [weak self] event in self?.handle(event) }
        self.client = client
        try await refresh()
        setupFailures = 0
        needsRepair = false
        setLink(.ready)
        log.note(.connection, connectedLine(), deviceID: status.deviceID)
        failedTries = nil
        alerts.reconnected()
        startRSSI()
        await startAudio()
    }

    private func refresh() async throws {
        guard let client else { throw BeeError.disconnected }
        let firmware = try await client.firmwareVersion()
        let hardware = firmware.hardwareRevision.flatMap(Hardware.init(revision:)) ?? known?.hardware ?? .legacy
        client.hardware = hardware

        var next = status
        next.firmware = firmware
        next.hardware = hardware
        if let ids = try? await client.secureIDs() {
            next.deviceID = ids.deviceID
            next.sealed = ids.sealed
        } else {
            next.deviceID = try await client.deviceID()
        }
        let battery = try await client.battery()
        next.battery = battery.percent
        next.charging = battery.charging
        next.millivolts = battery.millivolts
        let device = try await client.deviceStatus()
        next.state = device.state
        next.codec = device.codec
        next.brightness = try? await client.brightness()
        next.updated = .now
        status = next

        if var known, known.deviceID != next.deviceID || known.hardware != hardware {
            known.deviceID = next.deviceID
            known.hardware = hardware
            setKnown(known)
        }
        statusChanged()
    }

    private func handle(_ event: BeeEvent) {
        markActive()
        var source: String?
        var repeated = false
        switch event {
        case let .state(device):
            if device.state == status.state {
                // No change: a request's echo that's already logged, or the watchdog re-sending it.
                repeated = true
            } else if let request = stateRequest, request.target == device.state {
                source = request.source.rawValue
                stateRequest = nil
            } else {
                source = "from the Bee"
            }
            status.state = device.state
            if let codec = device.codec { status.codec = codec }
            // A003 is the truth: it also reports the Bee's own button toggling recording.
            switch device.state {
            case .recording: captureWanted = true
            case .mute: captureWanted = false
            default: break
            }
            if device.state != .recording { audio.pause(.stopped) }
        case let .battery(level):
            status.battery = level.percent
            status.millivolts = level.millivolts
        case let .charging(on):
            status.charging = on
            // The Bee on its charger: the day's audio is in. A good night to process it.
            if on { BackgroundWork.scheduleNightly() }
        case .doublePress, .hold, .other:
            break
        }
        status.updated = .now
        if !repeated { log.record(event, deviceID: status.deviceID, source: source) }
        statusChanged()
    }

    private func disconnected(_ peripheral: CBPeripheral, _ error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        if (error as? CBError)?.code == .peerRemovedPairingInformation { needsRepair = true }
        let wasReady = link == .ready
        teardownSession()
        if expectingDisconnect {
            if known != nil { log.note(.connection, "Powered off", deviceID: status.deviceID) }
        } else if wasReady {
            log.note(.connection, "Disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""), deviceID: status.deviceID)
            alerts.disconnected(name: known?.name ?? "Bee")
        }
        expectingDisconnect = false
        guard known != nil else { return }
        setLink(.searching)
        // Back off after failed setups (for example a declined pairing request) instead of spinning.
        let delay = setupFailures == 0 ? 0 : min(60, 1 << min(setupFailures, 6))
        scheduleReconnect(after: .seconds(delay))
    }

    private func teardownSession() {
        rssiTask?.cancel()
        rssiTask = nil
        watchdog?.cancel()
        watchdog = nil
        if audio.isRunning {
            if audio.status.stats.packets > 0 { log.note(.audio, "Audio: \(audio.summary)", deviceID: status.deviceID) }
            audio.stop(.disconnected)
        }
        sessionNonce = nil
        client?.channel.close()
        (transport as? BluetoothTransport)?.invalidate()
        transport = nil
        client = nil
        sessionOpen = false
        rssi = nil
    }

    private func clearKnown() {
        setKnown(nil)
        peripheral = nil
        status = BeeStatus()
        firmware = nil
        sessionOpen = false
        needsRepair = false
        setupFailures = 0
        failedTries = nil
        expectingDisconnect = false
        setLink(.unpaired)
        lastSnapshot = nil
        BeeSnapshot.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: BeeSnapshot.widgetKind)
        if central == nil { startBluetooth() }
    }

    private func setKnown(_ bee: KnownBee?) {
        known = bee
        guard persists else { return }
        if bee?.isDemo == true {
            UserDefaults.standard.set(true, forKey: BeeStore.demoKey)
        } else {
            UserDefaults.standard.removeObject(forKey: BeeStore.demoKey)
            KnownBee.save(bee)
        }
    }

    private func setLink(_ state: LinkState) {
        guard state != link else { return }
        link = state
        linkChanged = .now
        if state == .ready { resumeReadyWaiters() }
        publishSnapshot()
        refreshLight()
    }

    private func startRSSI() {
        rssiTask?.cancel()
        rssiTask = Task {
            while !Task.isCancelled {
                if self.isActive, let transport = self.transport {
                    self.rssi = try? await transport.readRSSI()
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func foregrounded() {
        guard link == .ready else { return }
        Task { try? await refresh() }
    }

    private func backgrounded() {
        // Heavy work started in the foreground must not carry on in the background on the Bluetooth
        // keep-alive: the CPU monitor would kill the app, and the capture with it.
        if processor.isRunning && processor.owner == .foreground { processor.cancel() }
        if !processor.backlog.isEmpty { BackgroundWork.scheduleNightly() }
    }

    // MARK: - audio capture

    func log(_ kind: LogEntry.Kind, _ text: String) {
        log.note(kind, text, deviceID: status.deviceID)
    }

    /// "Process now": a continued background task if the system takes one, else right here.
    func processNow() {
        Task {
            if await BackgroundWork.processNow(self) { return }
            // Without a continued task, only process on screen: heavy work in the background on the
            // Bluetooth keep-alive would trip the CPU monitor and take the capture down with it.
            if isActive {
                await processor.process()
            } else {
                log.note(.other, "Processing waits for the app to be open, or for tonight's run on the charger")
                BackgroundWork.scheduleNightly()
            }
        }
    }

    private func setUpCapture() {
        processor.openSegmentID = { [weak self] in self?.recorder.current?.id }
        processor.onLog = { [weak self] text in self?.log.note(.other, text) }
        processor.onDigest = { [weak self] note in
            guard Calendar.current.isDateInToday(note.day) else { return }
            self?.alerts.digest(day: note.day, headline: note.headline, commitments: note.commitments)
        }
        audio.onStatus = { [weak self] status in
            guard let self else { return }
            self.capture = status
            if let last = status.lastFrame, Date.now.timeIntervalSince(last) < 5 { self.stallRearms = 0 }
            self.refreshLight()
        }
        MuteFromActivityIntent.handler = { [weak self] in try await self?.setMutedFromIntent(true, from: .lockScreen) }
        audio.onVerified = { [weak self] in
            guard let self else { return }
            self.captureProblem = nil
            self.stallRearms = 0
            self.log.note(.audio, "Audio verified (MTU \(self.audio.status.maximumNotificationLength + 3))", deviceID: self.status.deviceID)
        }
        audio.onProblem = { [weak self] problem in
            guard let self else { return }
            switch problem {
            case let .undecryptable(packets):
                self.captureProblem = "Audio arrives but doesn't decrypt with the saved key."
                self.log.note(.audio, "Audio doesn't decrypt (\(packets) packets): wrong key or nonce", deviceID: self.status.deviceID)
            case let .writeFailed(reason):
                self.captureProblem = "Couldn't save audio: \(reason)"
                self.log.note(.audio, "Couldn't save audio: \(reason)", deviceID: self.status.deviceID)
            }
        }
        let context = container.mainContext
        recorder.onOpen = { [weak self] segment in
            let row = AudioSegment(segment)
            context.insert(row)
            try? context.save()
            self?.segmentRows[segment.id] = row
        }
        recorder.onUpdate = { [weak self] segment in
            guard let self, let row = self.segmentRows[segment.id] else { return }
            row.update(segment)
            // Saving every flush would be a write every 2 s, all day.
            if Date.now.timeIntervalSince(self.lastSegmentSave) >= 10 {
                self.lastSegmentSave = .now
                try? context.save()
            }
        }
        recorder.onClose = { [weak self] segment, reason in
            guard let self else { return }
            let row = self.segmentRows.removeValue(forKey: segment.id)
            row?.update(segment)
            row?.isOpen = false
            row?.closeReason = reason.rawValue
            try? context.save()
            BackgroundWork.scheduleNightly()
        }
        if persists {
            Diagnostics.start { [weak self] line in self?.log.note(.other, line) }
        }
    }

    /// The recording light follows whether the Bee is set to listen, and whether audio is arriving.
    private func refreshLight() {
        let fresh = capture.lastFrame.map { Date.now.timeIntervalSince($0) < 6 } ?? false
        // Only on a change: this runs for every audio packet.
        if link == .ready && capture.verified && fresh && status.state == .recording {
            if capturingSince == nil { capturingSince = .now }
        } else if capturingSince != nil {
            capturingSince = nil
        }
        guard persists else { return }
        light.update(
            listening: captureWanted && known != nil,
            capturing: link == .ready && capture.verified && fresh,
            connected: link == .ready,
            name: known?.name ?? "Bee",
            foreground: isActive
        )
    }

    /// Opens the session (if there's a key) and subscribes to audio. A reconnect isn't capturing until
    /// verified frames arrive.
    private func startAudio() async {
        guard let client, let transport, link == .ready, let deviceID = status.deviceID, token(for: deviceID) != nil else { return }
        do {
            let nonce = try await ensureSession(client, deviceID: deviceID)
            guard let token = token(for: deviceID) else { return }
            if !audio.isRunning {
                try await audio.start(transport: transport, key: token.key, nonce: nonce, deviceID: deviceID)
            }
            // The Bee's own state decides. The app never turns the microphone on by itself: it records
            // only after a press of the Bee's button or Unmute here.
            switch status.state {
            case .recording:
                if !captureWanted {
                    log.note(.audio, "The Bee was already listening when it connected; what it heard before that wasn't saved", deviceID: deviceID)
                }
                captureWanted = true
            case .mute:
                if captureWanted { log.note(.audio, "The Bee came back muted, so nothing is being recorded", deviceID: deviceID) }
                captureWanted = false
            default:
                break
            }
            startWatchdog()
            #if DEBUG
            runCaptureTestIfAsked()
            #endif
        } catch is MissingKeyError {
            return
        } catch {
            log.note(.audio, "Audio didn't start: \(error.localizedDescription)", deviceID: deviceID)
        }
    }

    #if DEBUG
    @ObservationIgnored private var captureTestStarted = false

    /// On-device test hook: launched with `-captureSeconds N`, listens for N seconds once the session is
    /// up, mutes again, and with `-processAfter YES` runs the pipeline on what it got.
    /// `-processNow YES`: processes at launch, as if "Process Now" had been tapped.
    /// `-replanFrom <ISO 8601 date>`: first plans conversations again from that time.
    private func processNowIfAsked() {
        if let from = UserDefaults.standard.string(forKey: "replanFrom").flatMap({ try? Date($0, strategy: .iso8601) }) {
            processor.replan(from: from)
            log.note(.other, "Test: planning conversations again from \(from.formatted(date: .abbreviated, time: .standard))")
        }
        guard UserDefaults.standard.bool(forKey: "processNow") else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            processNow()
        }
    }

    private func runCaptureTestIfAsked() {
        let seconds = UserDefaults.standard.integer(forKey: "captureSeconds")
        guard seconds > 0, !captureTestStarted else { return }
        captureTestStarted = true
        Task {
            log.note(.audio, "Capture test: listening for \(seconds) s", deviceID: status.deviceID)
            await setMuted(false, from: .test)
            try? await Task.sleep(for: .seconds(seconds))
            await setMuted(true, from: .test)
            recorder.close(.stopped)
            log.note(.audio, "Capture test done: \(audio.summary)", deviceID: status.deviceID)
            if UserDefaults.standard.bool(forKey: "processAfter") { processNow() }
        }
    }
    #endif

    /// Ends idle segments, and re-subscribes if the Bee says it's recording but no audio has come in a while.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.markActive()
                self.recorder.closeIfIdle()
                self.refreshLight()
                guard self.link == .ready, self.audio.isRunning, self.status.state == .recording else { continue }
                let last = self.audio.status.lastFrame ?? self.audio.status.started ?? .now
                // Back off: 15 s, then 30, 60, at most every 2 minutes.
                let allowed = 15 * Double(1 << min(self.stallRearms, 3))
                guard Date.now.timeIntervalSince(last) > allowed else { continue }
                self.stallRearms += 1
                self.log.note(.audio, "No audio for \(Int(Date.now.timeIntervalSince(last))) s while recording; re-subscribing", deviceID: self.status.deviceID)
                try? await self.audio.rearm()
                try? await self.client?.setState(.recording)
            }
        }
    }

    // MARK: - launches

    /// Logs how the app started and when it last ran before that, so a gap in the log can be told apart
    /// from a quiet day. iOS doesn't say when a suspended app was ended, only that it's starting again.
    private func noteLaunch() {
        let launched = Date.now
        let before = [UserDefaults.standard.object(forKey: BeeStore.lastActiveKey) as? Date, log.latest].compactMap { $0 }.max()
        markActive(force: true)
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.note(.app, "FreeBee is closing (swiped away, or ended by iOS while running)")
            }
        }
        Task {
            // By then iOS has handed over any Bluetooth state, and the scene is up if there is one.
            try? await Task.sleep(for: .seconds(2))
            var line = if UIApplication.shared.applicationState != .background {
                "FreeBee opened"
            } else if restoredByBluetooth {
                "iOS started FreeBee in the background for the Bee"
            } else {
                "FreeBee started in the background"
            }
            if let before, launched.timeIntervalSince(before) > 120 {
                line += "; it last ran \(before.formatted(date: .abbreviated, time: .shortened))"
            }
            log.note(.app, line, at: launched)
        }
    }

    /// When the app last ran, for the next launch to report. Written at most once a minute.
    private func markActive(force: Bool = false) {
        guard persists, force || Date.now.timeIntervalSince(lastActiveWrite) >= 60 else { return }
        lastActiveWrite = .now
        UserDefaults.standard.set(Date.now, forKey: BeeStore.lastActiveKey)
    }

    /// "Connected · battery 95% · after 6 failed tries from 5:19 to 5:22 PM"
    private func connectedLine() -> String {
        var parts = ["Connected"]
        if let battery = status.battery {
            parts.append("battery \(battery)%" + (status.charging == true ? ", charging" : ""))
        }
        if let tries = failedTries {
            let first = tries.first.formatted(date: .omitted, time: .shortened)
            let last = tries.last.formatted(date: .omitted, time: .shortened)
            parts.append("after \(tries.count) failed \(tries.count == 1 ? "try" : "tries") " + (first == last ? "at \(first)" : "from \(first) to \(last)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - widget and alerts

    private func statusChanged() {
        alerts.battery(percent: status.battery, charging: status.charging, name: known?.name ?? "Bee")
        publishSnapshot()
    }

    private func publishSnapshot() {
        guard let known else { return }
        let snapshot = BeeSnapshot(
            name: known.name,
            battery: status.battery,
            charging: status.charging ?? false,
            activity: status.state?.activity ?? .unknown,
            connected: link == .ready,
            updated: status.updated ?? .now
        )
        guard !snapshot.sameContent(as: lastSnapshot) else { return }
        lastSnapshot = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: BeeSnapshot.widgetKind)
    }
}
