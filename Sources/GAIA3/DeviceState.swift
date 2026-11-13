import Foundation

public struct DeviceState: Equatable {
    public struct PairedDevice: Identifiable, Equatable {
        public var id: UInt8 { index }
        public let index: UInt8
        public let connected: Bool
        public let name: String

        public init(index: UInt8, connected: Bool, name: String) {
            self.index = index
            self.connected = connected
            self.name = name
        }
    }

    public var modelID = ""
    public var firmware = ""
    public var serial = ""
    public var hwRevision = ""
    public var battery: Int?
    public var codec: String?

    public var noise = NoiseControl()

    public var eqBands: [Float] = Array(repeating: 0, count: EqPreset.bandLabels.count)
    public var eqMinGain: Float = -EqPreset.gainLimit
    public var eqMaxGain: Float = EqPreset.gainLimit
    public var bassBoost: Bool?

    public var smartPause: Bool?
    public var onHeadDetection: Bool?
    public var autoAnswer: Bool?
    public var comfortCall: Bool?
    public var lowLatency: Bool?
    public var sidetone: UInt8?
    public var promptMode: UInt8?
    public var promptLanguage: UInt8?
    public var audioMode: UInt8?
    public var btCompatibility: UInt8?
    public var autoPowerOffSeconds: UInt16?

    public var pairedCount: Int?
    public var pairedDevices: [PairedDevice] = []

    public init() {}

    public var eqPreset: String { EqPreset.match(eqBands) }

    public static func gain(fromByte byte: UInt8) -> Float { Float(Int8(bitPattern: byte)) / 10 }

    public static func gainByte(_ gain: Float) -> UInt8 {
        UInt8(bitPattern: Int8(clamping: Int((gain * 10).rounded())))
    }

    public mutating func apply(_ frame: GAIA3.Frame) {
        guard frame.kind == .response || frame.kind == .notification else { return }
        let payload = frame.payload
        switch frame.command {
        case Cmd.ancOnResp, Cmd.ancOnNotif:
            if let value = payload.first { noise.ancOn = value != 0 }
        case Cmd.transparencyOnResp, Cmd.transparencyOnNotif:
            if let value = payload.first { noise.transparencyOn = value != 0 }
        case Cmd.transparencyResp, Cmd.transparencyNotif:
            if let value = payload.first { noise.transparencyLevel = value }
        case Cmd.ancModeResp, Cmd.ancModeNotif:
            noise.applyModePayload(payload)
        case Cmd.batteryResp, Cmd.batteryNotif:
            if payload.count >= 2 { battery = Int(payload[1...].max() ?? payload[1]) }
            else if let value = payload.first { battery = Int(value) }
        case Cmd.codecResp:
            if let value = payload.first { codec = CodecID.name(value) }
        case Cmd.modelIdResp:
            modelID = String(bytes: payload.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        case Cmd.fwVersionResp:
            if payload.count >= 6 {
                let a = (Int(payload[0]) << 8) | Int(payload[1])
                let b = (Int(payload[2]) << 8) | Int(payload[3])
                let c = (Int(payload[4]) << 8) | Int(payload[5])
                firmware = "\(a).\(b).\(c)"
            }
        case Cmd.serialResp:
            serial = String(bytes: payload.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        case Cmd.hwRevisionResp:
            if payload.count >= 2 { hwRevision = "\((Int(payload[0]) << 8) | Int(payload[1]))" }
        case Cmd.smartPauseResp:
            if let value = payload.first { smartPause = value != 0 }
        case Cmd.onHeadResp:
            if let value = payload.first { onHeadDetection = value != 0 }
        case Cmd.autoAnswerResp:
            if let value = payload.first { autoAnswer = value != 0 }
        case Cmd.comfortCallResp:
            if let value = payload.first { comfortCall = value != 0 }
        case Cmd.lowLatencyResp:
            if let value = payload.first { lowLatency = value != 0 }
        case Cmd.sidetoneResp:
            if let value = payload.first { sidetone = value }
        case Cmd.promptModeResp:
            if let value = payload.first { promptMode = value }
        case Cmd.promptLangResp:
            if let value = payload.first { promptLanguage = value }
        case Cmd.audioModeResp, Cmd.audioModeNotif:
            if let value = payload.last { audioMode = value }
        case Cmd.btCompatResp:
            if let value = payload.first { btCompatibility = value }
        case Cmd.timerResp:
            if payload.count >= 3, payload[0] == Cmd.powerOffTimerID {
                autoPowerOffSeconds = (UInt16(payload[1]) << 8) | UInt16(payload[2])
            }
        case Cmd.eqConfigResp:
            if payload.count >= 3 {
                let count = Int(payload[0])
                let low = Self.gain(fromByte: payload[1])
                let high = Self.gain(fromByte: payload[2])
                if (1...10).contains(count), count != eqBands.count {
                    eqBands = Array(repeating: 0, count: count)
                }
                if low < high {
                    eqMinGain = low
                    eqMaxGain = high
                }
            }
        case Cmd.eqBandResp:
            if payload.count >= 2, eqBands.indices.contains(Int(payload[0])) {
                eqBands[Int(payload[0])] = Self.gain(fromByte: payload[1])
            }
        case Cmd.eqNotif:
            if payload.count >= eqBands.count {
                for index in eqBands.indices { eqBands[index] = Self.gain(fromByte: payload[index]) }
            }
        case Cmd.bassBoostResp, Cmd.bassBoostNotif:
            if let value = payload.first { bassBoost = value != 0 }
        case Cmd.pairedListSizeResp:
            let count = Int(payload.last ?? 0)
            pairedCount = count
            pairedDevices.removeAll { Int($0.index) >= count }
        case Cmd.pairedDeviceInfoResp:
            if payload.count >= 3 {
                let index = payload[0]
                let connected = payload[2] != 0
                let nameBytes = Array(payload[3...]).prefix { $0 != 0 }
                let name = String(bytes: nameBytes, encoding: .utf8) ?? "Device \(index)"
                pairedDevices.removeAll { $0.index == index }
                pairedDevices.append(PairedDevice(index: index, connected: connected, name: name))
                pairedDevices.sort { $0.index < $1.index }
            }
        default:
            break
        }
    }
}
