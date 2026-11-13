import Foundation

public enum GAIA3 {
    public static let startOfFrame: UInt8 = 0xFF
    public static let flags: UInt8 = 0x03
    public static let vendorSennheiser: UInt16 = 0x0495
    public static let vendorQualcomm: UInt16 = 0x001D

    public struct Frame: Equatable {
        public enum Kind: String {
            case request = "REQ"
            case response = "RSP"
            case notification = "NTF"
            case error = "ERR"
        }

        public let vendor: UInt16
        public let command: UInt16
        public let payload: [UInt8]

        public init(vendor: UInt16, command: UInt16, payload: [UInt8]) {
            self.vendor = vendor
            self.command = command
            self.payload = payload
        }

        public var kind: Kind {
            if command & 0x0080 != 0 && command & 0x0100 != 0 { return .error }
            if command & 0x0100 != 0 { return .response }
            if command & 0x0080 != 0 { return .notification }
            return .request
        }

        public var baseCommand: UInt16 { command & ~0x0180 }

        public var bytes: [UInt8] { GAIA3.encode(vendor: vendor, command: command, payload: payload) }

        public var hex: String { GAIA3.hex(bytes) }
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func parseHex(_ text: String) -> [UInt8]? {
        let digits = text.filter { !$0.isWhitespace && $0 != ":" && $0 != "," }
        guard !digits.isEmpty, digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    public static func encode(vendor: UInt16 = GAIA3.vendorSennheiser,
                              command: UInt16,
                              payload: [UInt8] = []) -> [UInt8] {
        var bytes: [UInt8] = [startOfFrame, flags]
        let len = UInt16(payload.count)
        bytes.append(UInt8((len >> 8) & 0xFF))
        bytes.append(UInt8(len & 0xFF))
        bytes.append(UInt8((vendor >> 8) & 0xFF))
        bytes.append(UInt8(vendor & 0xFF))
        bytes.append(UInt8((command >> 8) & 0xFF))
        bytes.append(UInt8(command & 0xFF))
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func split(_ buffer: [UInt8]) -> (frames: [Frame], remainder: [UInt8]) {
        var frames: [Frame] = []
        var index = 0
        while buffer.count - index >= 8 {
            guard buffer[index] == startOfFrame, buffer[index + 1] == flags else {
                index += 1
                continue
            }
            let length = (Int(buffer[index + 2]) << 8) | Int(buffer[index + 3])
            let total = 8 + length
            if buffer.count - index < total { break }
            let vendor = (UInt16(buffer[index + 4]) << 8) | UInt16(buffer[index + 5])
            let command = (UInt16(buffer[index + 6]) << 8) | UInt16(buffer[index + 7])
            let payload = Array(buffer[(index + 8)..<(index + total)])
            frames.append(Frame(vendor: vendor, command: command, payload: payload))
            index += total
        }
        return (frames, Array(buffer[index...]))
    }
}

public enum Cmd {
    public static let registerNotification: UInt16 = 0x0007
    public static let factoryReset: UInt16 = 0x0040

    public static let serialGet: UInt16 = 0x0003
    public static let serialResp: UInt16 = 0x0103

    public static let onHeadSet: UInt16 = 0x0400
    public static let onHeadGet: UInt16 = 0x0401
    public static let onHeadResp: UInt16 = 0x0501
    public static let btCompatSet: UInt16 = 0x0405
    public static let btCompatGet: UInt16 = 0x0406
    public static let btCompatResp: UInt16 = 0x0506

    public static let timerSet: UInt16 = 0x0600
    public static let timerGet: UInt16 = 0x0601
    public static let timerResp: UInt16 = 0x0701
    public static let batteryGet: UInt16 = 0x0603
    public static let batteryResp: UInt16 = 0x0703
    public static let batteryNotif: UInt16 = 0x0683

    public static let codecGet: UInt16 = 0x0800
    public static let codecResp: UInt16 = 0x0900

    public static let promptModeSet: UInt16 = 0x0801
    public static let promptModeGet: UInt16 = 0x0802
    public static let promptModeResp: UInt16 = 0x0902
    public static let audioModeSet: UInt16 = 0x0803
    public static let audioModeGet: UInt16 = 0x0804
    public static let audioModeResp: UInt16 = 0x0904
    public static let audioModeNotif: UInt16 = 0x0884
    public static let sidetoneSet: UInt16 = 0x0805
    public static let sidetoneGet: UInt16 = 0x0806
    public static let sidetoneResp: UInt16 = 0x0906
    public static let promptLangGet: UInt16 = 0x0807
    public static let promptLangResp: UInt16 = 0x0907

    public static let autoAnswerSet: UInt16 = 0x080A
    public static let autoAnswerGet: UInt16 = 0x080B
    public static let autoAnswerResp: UInt16 = 0x090B
    public static let smartPauseSet: UInt16 = 0x080C
    public static let smartPauseGet: UInt16 = 0x080D
    public static let smartPauseResp: UInt16 = 0x090D

    public static let comfortCallSet: UInt16 = 0x0814
    public static let comfortCallGet: UInt16 = 0x0815
    public static let comfortCallResp: UInt16 = 0x0915
    public static let lowLatencySet: UInt16 = 0x0817
    public static let lowLatencyGet: UInt16 = 0x0818
    public static let lowLatencyResp: UInt16 = 0x0918

    public static let eqConfigGet: UInt16 = 0x1000
    public static let eqConfigResp: UInt16 = 0x1100
    public static let eqBandSet: UInt16 = 0x1001
    public static let eqBandGet: UInt16 = 0x1002
    public static let eqBandSetResp: UInt16 = 0x1101
    public static let eqBandResp: UInt16 = 0x1102
    public static let eqNotif: UInt16 = 0x1082
    public static let bassBoostSet: UInt16 = 0x1008
    public static let bassBoostGet: UInt16 = 0x1009
    public static let bassBoostResp: UInt16 = 0x1109
    public static let bassBoostNotif: UInt16 = 0x1089

    public static let hwRevisionGet: UInt16 = 0x1200
    public static let hwRevisionResp: UInt16 = 0x1300
    public static let fwVersionGet: UInt16 = 0x1201
    public static let fwVersionResp: UInt16 = 0x1301
    public static let modelIdGet: UInt16 = 0x1206
    public static let modelIdResp: UInt16 = 0x1306

    public static let pairedListSizeGet: UInt16 = 0x1400
    public static let pairedListSizeResp: UInt16 = 0x1500
    public static let pairedDeviceInfo: UInt16 = 0x1401
    public static let pairedDeviceInfoResp: UInt16 = 0x1501
    public static let pairedConnect: UInt16 = 0x1402
    public static let pairedDisconnect: UInt16 = 0x1403
    public static let pairedDelete: UInt16 = 0x1405

    public static let transparencyOnSet: UInt16 = 0x1804
    public static let transparencyOnGet: UInt16 = 0x1805
    public static let transparencyOnResp: UInt16 = 0x1905
    public static let transparencyOnNotif: UInt16 = 0x1885

    public static let ancModeSet: UInt16 = 0x1A00
    public static let ancModeGet: UInt16 = 0x1A01
    public static let ancModeResp: UInt16 = 0x1B01
    public static let ancModeNotif: UInt16 = 0x1A81
    public static let transparencySet: UInt16 = 0x1A02
    public static let transparencyGet: UInt16 = 0x1A03
    public static let transparencyResp: UInt16 = 0x1B03
    public static let transparencyNotif: UInt16 = 0x1A83
    public static let ancOnSet: UInt16 = 0x1A04
    public static let ancOnGet: UInt16 = 0x1A05
    public static let ancOnResp: UInt16 = 0x1B05
    public static let ancOnNotif: UInt16 = 0x1A85

    public static let powerOffTimerID: UInt8 = 0

    public static let names: [UInt16: String] = [
        registerNotification: "Register notification", factoryReset: "Factory reset",
        onHeadSet: "Set on-head detection", onHeadGet: "Get on-head detection",
        btCompatSet: "Set BT compatibility", btCompatGet: "Get BT compatibility",
        timerSet: "Set timer", timerGet: "Get timer", batteryGet: "Get battery",
        codecGet: "Get codec",
        promptModeSet: "Set prompt mode", promptModeGet: "Get prompt mode",
        audioModeSet: "Set audio mode", audioModeGet: "Get audio mode",
        sidetoneSet: "Set sidetone", sidetoneGet: "Get sidetone",
        promptLangGet: "Get prompt language",
        autoAnswerSet: "Set auto answer", autoAnswerGet: "Get auto answer",
        smartPauseSet: "Set smart pause", smartPauseGet: "Get smart pause",
        comfortCallSet: "Set comfort call", comfortCallGet: "Get comfort call",
        lowLatencySet: "Set low latency", lowLatencyGet: "Get low latency",
        eqConfigGet: "Get EQ config", eqBandSet: "Set EQ band", eqBandGet: "Get EQ band",
        bassBoostSet: "Set bass boost", bassBoostGet: "Get bass boost",
        hwRevisionGet: "Get HW revision", fwVersionGet: "Get firmware", modelIdGet: "Get model",
        pairedListSizeGet: "Get paired list size", pairedDeviceInfo: "Get paired device",
        pairedConnect: "Connect paired device", pairedDisconnect: "Disconnect paired device",
        pairedDelete: "Delete paired device",
        transparencyOnSet: "Set transparency on", transparencyOnGet: "Get transparency on",
        ancModeSet: "Set noise mode", ancModeGet: "Get noise mode",
        transparencySet: "Set transparency level", transparencyGet: "Get transparency level",
        ancOnSet: "Set ANC on", ancOnGet: "Get ANC on",
    ]

    public static func name(_ command: UInt16, vendor: UInt16 = GAIA3.vendorSennheiser) -> String? {
        let base = command & ~0x0180
        if vendor == GAIA3.vendorQualcomm { return base == serialGet ? "Get serial" : nil }
        return names[base]
    }
}

public enum FeatureID: UInt8 {
    case battery = 3
    case genericAudio = 4
    case userEQ = 8
    case versions = 9
    case deviceManagement = 10
    case mmi = 11
    case transparentHearing = 12
    case anc = 13
}

public struct NoiseControl: Equatable {
    public init() {}

    public enum Mode: String, CaseIterable, Identifiable {
        case anc = "ANC"
        case transparency = "Transparency"
        case off = "Off"
        public var id: String { rawValue }
    }

    public enum AntiWind: UInt8, CaseIterable, Identifiable {
        case off = 0
        case max = 1
        case auto = 2
        public var id: UInt8 { rawValue }
        public var label: String {
            switch self {
            case .off: return "Off"
            case .max: return "Max"
            case .auto: return "Auto"
            }
        }
    }

    public var ancOn: Bool?
    public var transparencyOn: Bool?
    public var transparencyLevel: UInt8 = 50
    public var antiWind: AntiWind?
    public var adaptiveANC: Bool?

    public var activeMode: Mode? {
        if transparencyOn == true { return .transparency }
        if ancOn == true { return .anc }
        if ancOn == false { return .off }
        return nil
    }

    public mutating func applyModePayload(_ payload: [UInt8]) {
        guard payload.count >= 6 else { return }
        var pairs: [(UInt8, UInt8)] = []
        for i in stride(from: 0, to: 6, by: 2) { pairs.append((payload[i], payload[i + 1])) }
        for (mode, state) in pairs {
            switch mode {
            case 1: antiWind = AntiWind(rawValue: state)
            case 3: adaptiveANC = state == 1 || state == 2
            default: break
            }
        }
    }
}

public enum CodecID {
    public static let names: [UInt8: String] = [
        0: "SBC", 1: "AAC", 2: "aptX", 3: "aptX-LL", 4: "MP3", 5: "aptX-HD",
        6: "Faststream", 7: "LHDC", 8: "aptX Adaptive", 9: "aptX Lossless",
        10: "LC3", 255: "—",
    ]
    public static func name(_ id: UInt8) -> String { names[id] ?? String(format: "0x%02X", id) }
}

public enum EqPreset {
    public static let bandLabels = ["50", "250", "800", "3k", "8k"]
    public static let bandFrequencies: [Double] = [50, 250, 800, 3000, 8000]
    public static let all: [(name: String, gains: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0]),
        ("Rock", [0, 0, 3, 3, -1]),
        ("Pop", [0, -5, 0, 5, 0]),
        ("Dance", [2, -3, -3, 1, 1]),
        ("Hip-Hop", [3, -1, -4, 2, 0]),
        ("Classical", [0, 0, 0, 1, 2]),
        ("Movie", [0, 0, 2, 2, -1]),
        ("Jazz", [-3, 0, 2, 2, 0]),
    ]
    public static let bassBoost: [Float] = [5, -2, 0, 0, 0]
    public static let gainLimit: Float = 6

    public static let bassBoostName = "Bass Boost"
    public static let customName = "Custom"

    public static func match(_ gains: [Float]) -> String {
        for preset in all where preset.gains == gains { return preset.name }
        if gains == bassBoost { return bassBoostName }
        return customName
    }

    public static func gains(named name: String) -> [Float]? {
        if name == bassBoostName { return bassBoost }
        return all.first { $0.name == name }?.gains
    }
}

public enum PromptLanguage {
    public static let names: [UInt8: String] = [
        0: "English", 1: "German", 2: "French", 3: "Spanish",
        4: "Chinese", 5: "Japanese", 6: "Russian", 7: "Korean",
    ]
    public static func name(_ id: UInt8) -> String { names[id] ?? "—" }
}
