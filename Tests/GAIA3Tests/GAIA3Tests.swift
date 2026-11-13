import XCTest
@testable import GAIA3

final class GAIA3Tests: XCTestCase {
    func testEncodeGetBattery() {
        XCTAssertEqual(GAIA3.encode(command: Cmd.batteryGet),
                       [0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x06, 0x03])
    }

    func testEncodeSetANCOn() {
        XCTAssertEqual(GAIA3.encode(command: Cmd.ancOnSet, payload: [1]),
                       [0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x1A, 0x04, 0x01])
    }

    func testEncodeQualcommSerialGet() {
        XCTAssertEqual(GAIA3.encode(vendor: GAIA3.vendorQualcomm, command: Cmd.serialGet),
                       [0xFF, 0x03, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x03])
    }

    func testDecodeBatteryResponse() {
        let (frames, remainder) = GAIA3.split([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x03, 0x2A])
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload, [0x2A])
        XCTAssertEqual(frames.first?.kind, .response)
        XCTAssertTrue(remainder.isEmpty)
    }

    func testDecodeSetResponse() {
        let (frames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x1B, 0x04])
        XCTAssertEqual(frames.first?.command, 0x1B04)
        XCTAssertEqual(frames.first?.kind, .response)
    }

    func testDecodeModelIdResponse() {
        let payload = Array("ACCENTUM".utf8) + [0]
        var bytes: [UInt8] = [0xFF, 0x03, 0x00, UInt8(payload.count), 0x04, 0x95, 0x13, 0x06]
        bytes.append(contentsOf: payload)
        let (frames, _) = GAIA3.split(bytes)
        XCTAssertEqual(String(bytes: frames[0].payload.prefix { $0 != 0 }, encoding: .utf8), "ACCENTUM")
    }

    func testResyncAndPartialFrame() {
        let (frames, remainder) = GAIA3.split([0x00, 0x11,
                                               0xFF, 0x03, 0x00, 0x00, 0x04, 0x95, 0x06, 0x03,
                                               0xFF, 0x03, 0x00])
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(remainder, [0xFF, 0x03, 0x00])
    }

    func testConcatenatedFrames() {
        var bytes: [UInt8] = []
        bytes += GAIA3.encode(command: Cmd.batteryGet)
        bytes += GAIA3.encode(command: Cmd.ancOnGet)
        let (frames, remainder) = GAIA3.split(bytes)
        XCTAssertEqual(frames.map(\.command), [Cmd.batteryGet, Cmd.ancOnGet])
        XCTAssertTrue(remainder.isEmpty)
    }

    func testNoiseModePayloadParsing() {
        let (frames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x06, 0x04, 0x95, 0x1B, 0x01,
                                       0x01, 0x02, 0x02, 0x00, 0x03, 0x01])
        var noise = NoiseControl()
        noise.applyModePayload(frames[0].payload)
        XCTAssertEqual(noise.antiWind, .auto)
        XCTAssertEqual(noise.adaptiveANC, true)
    }

    func testNotificationClassification() {
        let (frames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x06, 0x83, 0x40])
        XCTAssertEqual(frames.first?.kind, .notification)
    }

    func testErrorClassification() {
        let (frames, _) = GAIA3.split([0xFF, 0x03, 0x00, 0x01, 0x04, 0x95, 0x07, 0x83, 0x01])
        XCTAssertEqual(frames.first?.kind, .error)
    }

    func testEqPresetMatching() {
        XCTAssertEqual(EqPreset.match([0, 0, 3, 3, -1]), "Rock")
        XCTAssertEqual(EqPreset.match([5, -2, 0, 0, 0]), "Bass Boost")
        XCTAssertEqual(EqPreset.match([1, 2, 3, 4, 5]), "Custom")
        XCTAssertEqual(EqPreset.gains(named: "Rock"), [0, 0, 3, 3, -1])
        XCTAssertEqual(EqPreset.gains(named: "Bass Boost"), [5, -2, 0, 0, 0])
        XCTAssertNil(EqPreset.gains(named: "Custom"))
    }

    func testBaseCommandStripsPduType() {
        let vendor = GAIA3.vendorSennheiser
        XCTAssertEqual(GAIA3.Frame(vendor: vendor, command: Cmd.batteryResp, payload: []).baseCommand, Cmd.batteryGet)
        XCTAssertEqual(GAIA3.Frame(vendor: vendor, command: Cmd.batteryNotif, payload: []).baseCommand, Cmd.batteryGet)
        XCTAssertEqual(GAIA3.Frame(vendor: vendor, command: Cmd.ancOnSet | 0x0180, payload: []).baseCommand, Cmd.ancOnSet)
    }

    func testParseHex() {
        XCTAssertEqual(GAIA3.parseHex("ff03 0000 0495 0603"), GAIA3.encode(command: Cmd.batteryGet))
        XCTAssertEqual(GAIA3.parseHex("FF:03"), [0xFF, 0x03])
        XCTAssertNil(GAIA3.parseHex(""))
        XCTAssertNil(GAIA3.parseHex("ff0"))
        XCTAssertNil(GAIA3.parseHex("zz"))
    }

    func testCommandNames() {
        XCTAssertEqual(Cmd.name(Cmd.batteryResp), "Get battery")
        XCTAssertEqual(Cmd.name(Cmd.serialResp, vendor: GAIA3.vendorQualcomm), "Get serial")
        XCTAssertNil(Cmd.name(0x7E00))
    }

    func testEqConfigResponseSetsBandCountAndRange() {
        var state = DeviceState()
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqConfigResp,
                                payload: [0x05, 0xC4, 0x3C, 0x00, 0x00]))
        XCTAssertEqual(state.eqBands.count, 5)
        XCTAssertEqual(state.eqMinGain, -6)
        XCTAssertEqual(state.eqMaxGain, 6)

        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqConfigResp, payload: [0x03, 0x9C, 0x64]))
        XCTAssertEqual(state.eqBands, [0, 0, 0])
        XCTAssertEqual(state.eqMaxGain, 10)
    }

    func testEqBandResponseAndGainEncoding() {
        var state = DeviceState()
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqBandResp, payload: [4, 0xF6]))
        XCTAssertEqual(state.eqBands[4], -1)
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqBandResp, payload: [9, 0x0A]))
        XCTAssertEqual(state.eqBands.count, 5)
        XCTAssertEqual(DeviceState.gainByte(-2.5), 0xE7)
        XCTAssertEqual(DeviceState.gain(fromByte: 0xE7), -2.5)
    }

    func testFrameLayoutsSeenOnAccentum() {
        var state = DeviceState()
        state.eqBands = [1, 2, 3, 4, 5]
        for hex in ["ff03000304950701000384",
                    "ff0300040495130000040000",
                    "ff030002049509040001",
                    "ff030002049515000004",
                    "ff03000a04951501010101695068 6f6e6500",
                    "ff03000804951501020200695061 6400",
                    "ff030005049510820000000000",
                    "ff03000604951b01010002000300"] {
            let (frames, remainder) = GAIA3.split(GAIA3.parseHex(hex) ?? [])
            XCTAssertEqual(frames.count, 1, hex)
            XCTAssertTrue(remainder.isEmpty, hex)
            frames.forEach { state.apply($0) }
        }
        XCTAssertEqual(state.autoPowerOffSeconds, 900)
        XCTAssertEqual(state.hwRevision, "4")
        XCTAssertEqual(state.audioMode, 1)
        XCTAssertEqual(state.pairedCount, 4)
        XCTAssertEqual(state.pairedDevices.map(\.name), ["iPhone", "iPad"])
        XCTAssertEqual(state.pairedDevices.map(\.connected), [true, false])
        XCTAssertEqual(state.eqBands, [0, 0, 0, 0, 0])
        XCTAssertEqual(state.noise.antiWind, .off)
        XCTAssertEqual(state.noise.adaptiveANC, false)
    }

    func testSingleByteEqBandResponseIsIgnored() {
        var state = DeviceState()
        state.eqBands = [1, 2, 3, 4, 5]
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.eqBandResp, payload: [0]))
        XCTAssertEqual(state.eqBands, [1, 2, 3, 4, 5])
    }

    func testRequestAndErrorFramesDoNotChangeState() {
        var state = DeviceState()
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.batteryGet, payload: [50]))
        state.apply(GAIA3.Frame(vendor: GAIA3.vendorSennheiser, command: Cmd.batteryGet | 0x0180, payload: [1]))
        XCTAssertEqual(state, DeviceState())
    }

    func testPairedListShrinksWithReportedSize() {
        var state = DeviceState()
        let vendor = GAIA3.vendorSennheiser
        state.apply(GAIA3.Frame(vendor: vendor, command: Cmd.pairedListSizeResp, payload: [2]))
        state.apply(GAIA3.Frame(vendor: vendor, command: Cmd.pairedDeviceInfoResp, payload: [1, 0, 0] + Array("Phone".utf8) + [0]))
        state.apply(GAIA3.Frame(vendor: vendor, command: Cmd.pairedDeviceInfoResp, payload: [0, 0, 1] + Array("Mac".utf8) + [0]))
        XCTAssertEqual(state.pairedDevices.map(\.name), ["Mac", "Phone"])
        XCTAssertEqual(state.pairedDevices.map(\.connected), [true, false])
        state.apply(GAIA3.Frame(vendor: vendor, command: Cmd.pairedListSizeResp, payload: [1]))
        XCTAssertEqual(state.pairedDevices.map(\.name), ["Mac"])
    }
}
