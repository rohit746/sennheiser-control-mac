import Foundation
import GAIA3

final class MemorySettings: SettingsStore {
    private var values: [String: Any] = [:]

    func string(forKey key: String) -> String? { values[key] as? String }

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class SimulatedDirectory: DeviceDirectory {
    static let address = "00-00-00-00-00-00"

    let headset = SimulatedHeadset()
    private var connectionHandler: ((String) -> Void)?

    func candidates() -> [Candidate] {
        [Candidate(address: Self.address, name: "ACCENTUM (simulated)", isConnected: true)]
    }

    func makeTransport(for candidate: Candidate) -> GAIATransport? { headset }

    func observeConnections(_ handler: @escaping (String) -> Void) { connectionHandler = handler }

    func simulateConnection() { connectionHandler?(Self.address) }
}

final class SimulatedHeadset: GAIATransport {
    weak var delegate: GAIATransportDelegate?

    var openDelay: TimeInterval = 0.2
    var latency: TimeInterval = 0.004
    var unreachable = false
    var rejected: Set<UInt16> = []
    var silent: Set<UInt16> = []
    private(set) var received: [GAIA3.Frame] = []

    var values: [UInt16: [UInt8]] = [
        Cmd.batteryGet: [72],
        Cmd.codecGet: [1],
        Cmd.modelIdGet: Array("ACAEBT Black".utf8) + [0],
        Cmd.fwVersionGet: [0, 3, 0, 34, 0, 0],
        Cmd.hwRevisionGet: [0, 4],
        Cmd.ancOnGet: [1],
        Cmd.transparencyOnGet: [0],
        Cmd.transparencyGet: [50],
        Cmd.smartPauseGet: [1],
        Cmd.onHeadGet: [1],
        Cmd.autoAnswerGet: [1],
        Cmd.comfortCallGet: [0],
        Cmd.lowLatencyGet: [0],
        Cmd.sidetoneGet: [1],
        Cmd.promptModeGet: [2],
        Cmd.promptLangGet: [0],
        Cmd.audioModeGet: [0, 1],
        Cmd.btCompatGet: [1],
        Cmd.eqConfigGet: [5, 0xC4, 0x3C, 0, 0],
        Cmd.bassBoostGet: [0],
    ]
    var bands: [UInt8] = [0, 0, 30, 30, 0xF6]
    var noiseModes: [UInt8] = [2, 0, 1]
    var powerOffSeconds: UInt16 = 900
    var paired: [(name: String, connected: Bool)] = [("MacBook Pro", true), ("Pixel 9", false)]

    private static let setters: [UInt16: UInt16] = [
        Cmd.ancOnSet: Cmd.ancOnGet,
        Cmd.transparencyOnSet: Cmd.transparencyOnGet,
        Cmd.transparencySet: Cmd.transparencyGet,
        Cmd.smartPauseSet: Cmd.smartPauseGet,
        Cmd.onHeadSet: Cmd.onHeadGet,
        Cmd.autoAnswerSet: Cmd.autoAnswerGet,
        Cmd.comfortCallSet: Cmd.comfortCallGet,
        Cmd.lowLatencySet: Cmd.lowLatencyGet,
        Cmd.sidetoneSet: Cmd.sidetoneGet,
        Cmd.promptModeSet: Cmd.promptModeGet,
        Cmd.audioModeSet: Cmd.audioModeGet,
        Cmd.btCompatSet: Cmd.btCompatGet,
        Cmd.bassBoostSet: Cmd.bassBoostGet,
    ]

    private var generation = 0
    private var isOpen = false

    // MARK: - GAIATransport

    func open() {
        generation += 1
        delegate?.transport(self, status: "Connecting to simulated headset…")
        after(openDelay) { [self] in
            if unreachable {
                delegate?.transportDidClose(self, error: "Couldn't reach the simulated headset.")
            } else {
                isOpen = true
                delegate?.transportDidOpen(self)
            }
        }
    }

    func close() {
        generation += 1
        isOpen = false
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard isOpen else { return false }
        for frame in GAIA3.split(bytes).frames {
            received.append(frame)
            after(latency) { [self] in respond(to: frame) }
        }
        return true
    }

    func notify(_ command: UInt16, _ payload: [UInt8]) {
        guard isOpen else { return }
        delegate?.transport(self, didReceive: GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: command, payload: payload))
    }

    func drop() {
        guard isOpen else { return }
        close()
        delegate?.transportDidClose(self, error: nil)
    }

    // MARK: - Device behaviour

    private func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == expected else { return }
            work()
        }
    }

    private func reply(_ request: GAIA3.Frame, _ payload: [UInt8]) {
        delegate?.transport(self, didReceive: GAIA3.Frame(vendor: request.vendor, command: request.command | 0x0100, payload: payload))
    }

    private func fail(_ request: GAIA3.Frame) {
        delegate?.transport(self, didReceive: GAIA3.Frame(vendor: request.vendor, command: request.command | 0x0180, payload: [0x01]))
    }

    private func respond(to frame: GAIA3.Frame) {
        let payload = frame.payload
        if silent.contains(frame.command) { return }
        if rejected.contains(frame.command) { return fail(frame) }
        if frame.vendor == GAIA3.vendorQualcomm {
            return frame.command == Cmd.serialGet ? reply(frame, Array("SIM000000001".utf8)) : fail(frame)
        }
        switch frame.command {
        case Cmd.registerNotification:
            reply(frame, [])
        case Cmd.eqBandGet:
            guard let index = payload.first, index < bands.count else { return fail(frame) }
            reply(frame, [index, bands[Int(index)]])
        case Cmd.eqBandSet:
            guard payload.count >= 2, payload[0] < bands.count else { return fail(frame) }
            bands[Int(payload[0])] = payload[1]
            reply(frame, [])
        case Cmd.ancModeGet:
            reply(frame, [1, noiseModes[0], 2, noiseModes[1], 3, noiseModes[2]])
        case Cmd.ancModeSet:
            guard payload.count >= 2, (1...3).contains(payload[0]) else { return fail(frame) }
            noiseModes[Int(payload[0]) - 1] = payload[1]
            reply(frame, [])
        case Cmd.timerGet:
            guard payload.first == Cmd.powerOffTimerID else { return fail(frame) }
            reply(frame, [Cmd.powerOffTimerID, UInt8(powerOffSeconds >> 8), UInt8(powerOffSeconds & 0xFF)])
        case Cmd.timerSet:
            guard payload.count >= 3, payload[0] == Cmd.powerOffTimerID else { return fail(frame) }
            powerOffSeconds = (UInt16(payload[1]) << 8) | UInt16(payload[2])
            reply(frame, [])
        case Cmd.pairedListSizeGet:
            reply(frame, [UInt8(paired.count)])
        case Cmd.pairedDeviceInfo:
            guard let index = payload.first, index < paired.count else { return fail(frame) }
            let entry = paired[Int(index)]
            reply(frame, [index, 0, entry.connected ? 1 : 0] + Array(entry.name.utf8) + [0])
        case Cmd.pairedConnect, Cmd.pairedDisconnect:
            guard let index = payload.first, index < paired.count else { return fail(frame) }
            paired[Int(index)].connected = frame.command == Cmd.pairedConnect
            reply(frame, [])
        case Cmd.pairedDelete:
            guard let index = payload.first, index < paired.count else { return fail(frame) }
            paired.remove(at: Int(index))
            reply(frame, [])
        default:
            if let value = values[frame.command] {
                reply(frame, value)
            } else if let getter = Self.setters[frame.command] {
                values[getter] = payload
                reply(frame, [])
            } else {
                fail(frame)
            }
        }
    }
}
