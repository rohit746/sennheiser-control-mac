import Foundation
import Combine
import GAIA3

final class FrameLog: ObservableObject {
    struct Entry: Identifiable {
        enum Direction: String { case tx = ">>", rx = "<<", info = "··" }
        let id: Int
        let time: Date
        let direction: Direction
        let summary: String
        let hex: String
    }

    @Published private(set) var entries: [Entry] = []
    private var nextID = 0
    private static let limit = 800

    func append(_ direction: Entry.Direction, _ summary: String, _ hex: String = "") {
        entries.append(Entry(id: nextID, time: Date(), direction: direction, summary: summary, hex: hex))
        nextID += 1
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }

    var text: String {
        entries.map { entry in
            ([entry.direction.rawValue, entry.summary] + (entry.hex.isEmpty ? [] : [entry.hex])).joined(separator: " ")
        }.joined(separator: "\n")
    }
}

final class HeadphoneSession: ObservableObject {

    private enum Keys {
        static let lastAddress = "lastDeviceAddress"
        static let autoConnect = "autoConnect"
    }

    private struct Request {
        let vendor: UInt16
        let command: UInt16
        let payload: [UInt8]
        let slot: [UInt8]
        var shadow: (command: UInt16, prefix: [UInt8])?
    }

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var deviceName = "—"
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var lastError: String?
    @Published private(set) var device = DeviceState()
    @Published var autoConnect: Bool {
        didSet { settings.set(autoConnect, forKey: Keys.autoConnect) }
    }

    let log = FrameLog()
    var responseTimeout: TimeInterval = 0.5
    var reconnectDelay: TimeInterval = 1.5

    private let directory: DeviceDirectory
    private let settings: SettingsStore
    private var transport: GAIATransport?
    private var connectingAddress: String?
    private var lastAddress: String?
    private var queue: [Request] = []
    private var inFlight: Request?
    private var timeoutWork: DispatchWorkItem?
    private var restingAudioMode: UInt8?

    static let podcastAudioMode: UInt8 = 2

    init(directory: DeviceDirectory = BluetoothDirectory(), settings: SettingsStore = UserDefaults.standard) {
        self.directory = directory
        self.settings = settings
        lastAddress = settings.string(forKey: Keys.lastAddress)
        autoConnect = settings.object(forKey: Keys.autoConnect) as? Bool ?? true
    }

    var isIdle: Bool { inFlight == nil && queue.isEmpty }

    var preferredCandidate: Candidate? {
        candidates.first { $0.address == lastAddress } ?? (candidates.count == 1 ? candidates.first : nil)
    }

    // MARK: - Connection

    func start() {
        refreshCandidates()
        directory.observeConnections { [weak self] address in self?.deviceAppeared(address) }
        autoConnectIfPossible()
    }

    func refreshCandidates() {
        candidates = directory.candidates()
    }

    func connect(to candidate: Candidate) {
        teardown()
        lastError = nil
        guard let transport = directory.makeTransport(for: candidate) else {
            lastError = "\(candidate.name) is no longer available."
            statusMessage = "Not connected"
            return
        }
        connectingAddress = candidate.address
        deviceName = candidate.name
        isConnecting = true
        statusMessage = "Connecting…"
        log.append(.info, "Connecting to \(candidate.name) [\(candidate.address)]")
        self.transport = transport
        transport.delegate = self
        transport.open()
    }

    @discardableResult
    func connectPreferred() -> Bool {
        refreshCandidates()
        guard let candidate = preferredCandidate else { return false }
        connect(to: candidate)
        return true
    }

    func disconnect() {
        guard transport != nil else { return }
        teardown()
        lastError = nil
        statusMessage = "Not connected"
        log.append(.info, "Disconnected")
    }

    private func teardown() {
        timeoutWork?.cancel()
        timeoutWork = nil
        inFlight = nil
        queue.removeAll()
        transport?.delegate = nil
        transport?.close()
        transport = nil
        isConnected = false
        isConnecting = false
        device = DeviceState()
        restingAudioMode = nil
    }

    private func deviceAppeared(_ address: String) {
        guard address == lastAddress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            self?.refreshCandidates()
            self?.autoConnectIfPossible()
        }
    }

    private func autoConnectIfPossible() {
        guard autoConnect, !isConnected, !isConnecting,
              let candidate = candidates.first(where: { $0.address == lastAddress }),
              candidate.isConnected else { return }
        connect(to: candidate)
    }

    // MARK: - Request queue

    func send(_ command: UInt16, _ payload: [UInt8] = [], vendor: UInt16 = GAIA3.vendorSennheiser) {
        enqueue(Request(vendor: vendor, command: command, payload: payload, slot: payload, shadow: nil))
    }

    private func write(_ set: UInt16, _ payload: [UInt8], readBack get: UInt16,
                       index: [UInt8] = [], indexedRead: Bool = true,
                       optimistic change: (inout DeviceState) -> Void) {
        guard isConnected else { return }
        change(&device)
        let readPayload = indexedRead ? index : []
        enqueue(Request(vendor: GAIA3.vendorSennheiser, command: set, payload: payload, slot: index,
                        shadow: (get, readPayload)))
        send(get, readPayload)
    }

    private func enqueue(_ request: Request) {
        guard isConnected else { return }
        queue.removeAll { $0.vendor == request.vendor && $0.command == request.command && $0.slot == request.slot }
        queue.append(request)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty, let transport else { return }
        let request = queue.removeFirst()
        let bytes = GAIA3.encode(vendor: request.vendor, command: request.command, payload: request.payload)
        log.append(.tx, describe("REQ", vendor: request.vendor, command: request.command), GAIA3.hex(bytes))
        inFlight = request
        guard transport.write(bytes) else {
            log.append(.info, "Write failed — dropped \(queue.count + 1) queued request(s)")
            inFlight = nil
            queue.removeAll()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.requestTimedOut() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + responseTimeout, execute: work)
    }

    private func requestTimedOut() {
        guard let request = inFlight else { return }
        log.append(.info, String(format: "No response to 0x%04X — continuing", request.command))
        inFlight = nil
        timeoutWork = nil
        pump()
    }

    private func isShadowed(_ frame: GAIA3.Frame) -> Bool {
        guard frame.kind == .response || frame.kind == .notification else { return false }
        return ((inFlight.map { [$0] } ?? []) + queue).contains { request in
            guard let shadow = request.shadow, shadow.command == frame.baseCommand else { return false }
            return frame.kind == .notification || frame.payload.starts(with: shadow.prefix)
        }
    }

    private func describe(_ kind: String, vendor: UInt16, command: UInt16) -> String {
        var text = String(format: "%@ 0x%04X", kind, command)
        if vendor != GAIA3.vendorSennheiser { text += String(format: " vendor 0x%04X", vendor) }
        if let name = Cmd.name(command, vendor: vendor) { text += "  \(name)" }
        return text
    }

    func refreshAll() {
        guard isConnected else { return }
        log.append(.info, "Reading device state")
        for command in [Cmd.batteryGet, Cmd.ancOnGet, Cmd.transparencyOnGet, Cmd.transparencyGet, Cmd.ancModeGet,
                        Cmd.modelIdGet, Cmd.fwVersionGet, Cmd.codecGet, Cmd.eqConfigGet] {
            send(command)
        }
        for index in device.eqBands.indices { send(Cmd.eqBandGet, [UInt8(index)]) }
        for command in [Cmd.bassBoostGet, Cmd.smartPauseGet, Cmd.onHeadGet, Cmd.autoAnswerGet, Cmd.comfortCallGet,
                        Cmd.lowLatencyGet, Cmd.audioModeGet, Cmd.sidetoneGet, Cmd.promptModeGet, Cmd.promptLangGet] {
            send(command)
        }
        send(Cmd.timerGet, [Cmd.powerOffTimerID])
        send(Cmd.btCompatGet)
        send(Cmd.hwRevisionGet)
        send(Cmd.serialGet, vendor: GAIA3.vendorQualcomm)
        send(Cmd.pairedListSizeGet)
        for feature in [FeatureID.battery, .anc, .transparentHearing, .userEQ] {
            send(Cmd.registerNotification, [feature.rawValue])
        }
    }

    // MARK: - Controls

    func setNoiseMode(_ mode: NoiseControl.Mode) {
        let anc = mode == .anc
        let transparency = mode == .transparency
        let setANC = { [self] in
            write(Cmd.ancOnSet, [anc ? 1 : 0], readBack: Cmd.ancOnGet) { $0.noise.ancOn = anc }
        }
        let setTransparency = { [self] in
            write(Cmd.transparencyOnSet, [transparency ? 1 : 0], readBack: Cmd.transparencyOnGet) {
                $0.noise.transparencyOn = transparency
            }
        }
        if transparency {
            setANC()
            setTransparency()
        } else {
            setTransparency()
            setANC()
        }
    }

    func setTransparencyLevel(_ level: UInt8) {
        write(Cmd.transparencySet, [level], readBack: Cmd.transparencyGet) { $0.noise.transparencyLevel = level }
    }

    func setAntiWind(_ mode: NoiseControl.AntiWind) {
        write(Cmd.ancModeSet, [1, mode.rawValue], readBack: Cmd.ancModeGet, index: [1], indexedRead: false) {
            $0.noise.antiWind = mode
        }
    }

    func setAdaptiveANC(_ on: Bool) {
        write(Cmd.ancModeSet, [3, on ? 1 : 0], readBack: Cmd.ancModeGet, index: [3], indexedRead: false) {
            $0.noise.adaptiveANC = on
        }
    }

    func setSmartPause(_ on: Bool) {
        write(Cmd.smartPauseSet, [on ? 1 : 0], readBack: Cmd.smartPauseGet) { $0.smartPause = on }
    }

    func setOnHeadDetection(_ on: Bool) {
        write(Cmd.onHeadSet, [on ? 1 : 0], readBack: Cmd.onHeadGet) { $0.onHeadDetection = on }
    }

    func setAutoAnswer(_ on: Bool) {
        write(Cmd.autoAnswerSet, [on ? 1 : 0], readBack: Cmd.autoAnswerGet) { $0.autoAnswer = on }
    }

    func setComfortCall(_ on: Bool) {
        write(Cmd.comfortCallSet, [on ? 1 : 0], readBack: Cmd.comfortCallGet) { $0.comfortCall = on }
    }

    func setLowLatency(_ on: Bool) {
        write(Cmd.lowLatencySet, [on ? 1 : 0], readBack: Cmd.lowLatencyGet) { $0.lowLatency = on }
    }

    func setBassBoost(_ on: Bool) {
        write(Cmd.bassBoostSet, [on ? 1 : 0], readBack: Cmd.bassBoostGet) { $0.bassBoost = on }
    }

    func setSidetone(_ level: UInt8) {
        let level = min(level, 5)
        write(Cmd.sidetoneSet, [level], readBack: Cmd.sidetoneGet) { $0.sidetone = level }
    }

    func setPromptMode(_ mode: UInt8) {
        write(Cmd.promptModeSet, [mode], readBack: Cmd.promptModeGet) { $0.promptMode = mode }
    }

    func setPodcastMode(_ on: Bool) {
        let mode = on ? Self.podcastAudioMode : (restingAudioMode ?? 0)
        write(Cmd.audioModeSet, [0x00, mode], readBack: Cmd.audioModeGet) { $0.audioMode = mode }
    }

    func setBtCompatibility(_ betterCompatibility: Bool) {
        write(Cmd.btCompatSet, [betterCompatibility ? 1 : 0], readBack: Cmd.btCompatGet) {
            $0.btCompatibility = betterCompatibility ? 1 : 0
        }
    }

    func setAutoPowerOff(seconds: UInt16) {
        write(Cmd.timerSet, [Cmd.powerOffTimerID, UInt8((seconds >> 8) & 0xFF), UInt8(seconds & 0xFF)],
              readBack: Cmd.timerGet, index: [Cmd.powerOffTimerID]) { $0.autoPowerOffSeconds = seconds }
    }

    func applyEqPreset(_ gains: [Float]) {
        for (index, gain) in gains.enumerated() { setEqBand(index, gain) }
    }

    func setEqBand(_ index: Int, _ gain: Float) {
        guard device.eqBands.indices.contains(index) else { return }
        let gain = min(max(gain, device.eqMinGain), device.eqMaxGain)
        write(Cmd.eqBandSet, [UInt8(index), DeviceState.gainByte(gain)],
              readBack: Cmd.eqBandGet, index: [UInt8(index)]) { $0.eqBands[index] = gain }
    }

    func connectPairedDevice(at index: UInt8) {
        send(Cmd.pairedConnect, [index])
        refreshPairedList(after: [1, 4])
    }

    func disconnectPairedDevice(at index: UInt8) {
        send(Cmd.pairedDisconnect, [index])
        refreshPairedList(after: [1, 4])
    }

    func deletePairedDevice(at index: UInt8) {
        send(Cmd.pairedDelete, [index])
        refreshPairedList(after: [1])
    }

    private func refreshPairedList(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.send(Cmd.pairedListSizeGet)
            }
        }
    }

    func factoryReset() {
        log.append(.info, "Factory reset command sent")
        send(Cmd.factoryReset)
    }

    @discardableResult
    func sendRaw(hex: String) -> Bool {
        guard isConnected, let transport, let bytes = GAIA3.parseHex(hex) else { return false }
        log.append(.tx, "raw \(bytes.count)B", GAIA3.hex(bytes))
        return transport.write(bytes)
    }
}

extension HeadphoneSession: GAIATransportDelegate {
    func transport(_ transport: GAIATransport, status: String) {
        guard transport === self.transport else { return }
        statusMessage = status
    }

    func transport(_ transport: GAIATransport, log message: String) {
        log.append(.info, message)
    }

    func transportDidOpen(_ transport: GAIATransport) {
        guard transport === self.transport else { return }
        isConnecting = false
        isConnected = true
        statusMessage = "Connected"
        if let address = connectingAddress {
            lastAddress = address
            settings.set(address, forKey: Keys.lastAddress)
        }
        refreshAll()
    }

    func transport(_ transport: GAIATransport, didReceive frame: GAIA3.Frame) {
        guard transport === self.transport else { return }
        log.append(.rx, describe(frame.kind.rawValue, vendor: frame.vendor, command: frame.command), frame.hex)
        let shadowed = isShadowed(frame)
        if let request = inFlight, request.vendor == frame.vendor, request.command == frame.baseCommand,
           frame.kind == .response || frame.kind == .error {
            timeoutWork?.cancel()
            timeoutWork = nil
            inFlight = nil
        }
        if !shadowed {
            var next = device
            next.apply(frame)
            if next != device {
                let bandCount = device.eqBands.count
                device = next
                if next.eqBands.count != bandCount {
                    for index in next.eqBands.indices { send(Cmd.eqBandGet, [UInt8(index)]) }
                }
            }
            if let mode = device.audioMode, mode != Self.podcastAudioMode { restingAudioMode = mode }
            if frame.command == Cmd.pairedListSizeResp, let count = device.pairedCount {
                for index in 0..<min(count, 16) { send(Cmd.pairedDeviceInfo, [UInt8(index)]) }
            }
        }
        pump()
    }

    func transportDidClose(_ transport: GAIATransport, error: String?) {
        guard transport === self.transport else { return }
        let wasConnected = isConnected
        teardown()
        lastError = error ?? (wasConnected ? "The connection to \(deviceName) was lost." : nil)
        statusMessage = wasConnected ? "Disconnected" : "Not connected"
        log.append(.info, error ?? "Link closed")
    }
}
