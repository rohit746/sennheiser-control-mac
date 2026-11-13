import XCTest
import AppKit
import Combine
import SwiftUI
import GAIA3
@testable import SennheiserControl

final class SessionTests: XCTestCase {
    private var settings: MemorySettings!
    private var directory: SimulatedDirectory!
    private var session: HeadphoneSession!

    private var headset: SimulatedHeadset { directory.headset }

    override func setUp() {
        settings = MemorySettings()
        directory = SimulatedDirectory()
        headset.openDelay = 0
        headset.latency = 0
        session = makeSession()
    }

    override func tearDown() {
        session.disconnect()
    }

    private func makeSession() -> HeadphoneSession {
        let session = HeadphoneSession(directory: directory, settings: settings)
        session.responseTimeout = 0.05
        session.reconnectDelay = 0
        return session
    }

    private func spin(_ interval: TimeInterval = 0.002) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func settle(_ target: HeadphoneSession? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let target = target ?? session!
        let deadline = Date().addingTimeInterval(3)
        repeat { spin() } while (target.isConnecting || !target.isIdle) && Date() < deadline
        XCTAssertTrue(target.isIdle && !target.isConnecting, "session did not settle", file: file, line: line)
    }

    private func connect(file: StaticString = #filePath, line: UInt = #line) {
        session.refreshCandidates()
        session.connect(to: session.candidates[0])
        settle(file: file, line: line)
        XCTAssertTrue(session.isConnected, file: file, line: line)
    }

    private func writes(of command: UInt16) -> [GAIA3.Frame] {
        headset.received.filter { $0.command == command }
    }

    func testConnectReadsDeviceState() {
        connect()
        let device = session.device
        XCTAssertEqual(device.modelID, "ACAEBT Black")
        XCTAssertEqual(device.firmware, "3.34.0")
        XCTAssertEqual(device.serial, "SIM000000001")
        XCTAssertEqual(device.hwRevision, "4")
        XCTAssertEqual(device.battery, 72)
        XCTAssertEqual(device.codec, "AAC")
        XCTAssertEqual(device.noise.activeMode, .anc)
        XCTAssertEqual(device.noise.antiWind, .auto)
        XCTAssertEqual(device.noise.adaptiveANC, true)
        XCTAssertEqual(device.eqBands, [0, 0, 3, 3, -1])
        XCTAssertEqual(device.eqPreset, "Rock")
        XCTAssertEqual(device.eqMinGain, -6)
        XCTAssertEqual(device.eqMaxGain, 6)
        XCTAssertEqual(device.autoPowerOffSeconds, 900)
        XCTAssertEqual(device.pairedDevices.map(\.name), ["MacBook Pro", "Pixel 9"])
        XCTAssertEqual(writes(of: Cmd.registerNotification).map(\.payload),
                       [[FeatureID.battery.rawValue], [FeatureID.anc.rawValue],
                        [FeatureID.transparentHearing.rawValue], [FeatureID.userEQ.rawValue]])
    }

    func testRequestsAreSerialised() {
        headset.latency = 0.003
        session.refreshCandidates()
        session.connect(to: session.candidates[0])
        var outstanding = 0
        var maxOutstanding = 0
        let subscription = session.log.$entries.dropFirst().sink { entries in
            guard let entry = entries.last else { return }
            if entry.direction == .tx { outstanding += 1 } else if entry.direction == .rx { outstanding -= 1 }
            maxOutstanding = max(maxOutstanding, outstanding)
        }
        settle()
        subscription.cancel()
        XCTAssertGreaterThan(headset.received.count, 25)
        XCTAssertEqual(maxOutstanding, 1)
    }

    func testToggleIsOptimisticAndConfirmedByReadBack() {
        connect()
        session.setSmartPause(false)
        XCTAssertEqual(session.device.smartPause, false)
        settle()
        XCTAssertEqual(headset.values[Cmd.smartPauseGet], [0])
        XCTAssertEqual(session.device.smartPause, false)
        XCTAssertEqual(headset.received.suffix(2).map(\.command), [Cmd.smartPauseSet, Cmd.smartPauseGet])
    }

    func testRejectedWriteRevertsToDeviceValue() {
        connect()
        headset.rejected = [Cmd.comfortCallSet]
        session.setComfortCall(true)
        XCTAssertEqual(session.device.comfortCall, true)
        settle()
        XCTAssertEqual(session.device.comfortCall, false)
    }

    func testUnansweredRequestTimesOutAndQueueContinues() {
        connect()
        headset.silent = [Cmd.lowLatencySet]
        session.setLowLatency(true)
        session.setAutoAnswer(false)
        settle()
        XCTAssertEqual(session.device.lowLatency, false)
        XCTAssertEqual(session.device.autoAnswer, false)
        XCTAssertEqual(headset.values[Cmd.autoAnswerGet], [0])
        XCTAssertTrue(session.log.entries.contains { $0.summary.hasPrefix("No response to 0x0817") })
    }

    func testSliderWritesAreCoalesced() {
        connect()
        for level in 0...100 { session.setTransparencyLevel(UInt8(level)) }
        XCTAssertEqual(session.device.noise.transparencyLevel, 100)
        settle()
        let sets = writes(of: Cmd.transparencySet)
        XCTAssertLessThanOrEqual(sets.count, 2)
        XCTAssertEqual(sets.last?.payload, [100])
        XCTAssertEqual(headset.values[Cmd.transparencyGet], [100])
        XCTAssertEqual(session.device.noise.transparencyLevel, 100)
    }

    func testStaleReadBackDoesNotOverrideNewerValue() {
        connect()
        headset.latency = 0.02
        session.setTransparencyLevel(40)
        let deadline = Date().addingTimeInterval(2)
        while headset.received.last?.command != Cmd.transparencyGet, Date() < deadline { spin(0.001) }
        XCTAssertEqual(headset.received.last?.command, Cmd.transparencyGet)

        session.setTransparencyLevel(60)
        var observed: [UInt8] = []
        let subscription = session.$device.sink { observed.append($0.noise.transparencyLevel) }
        settle()
        subscription.cancel()
        XCTAssertFalse(observed.contains(40))
        XCTAssertEqual(session.device.noise.transparencyLevel, 60)
        XCTAssertEqual(headset.values[Cmd.transparencyGet], [60])
    }

    func testNoiseModeSwitchDrivesBothToggles() {
        connect()
        session.setNoiseMode(.transparency)
        XCTAssertEqual(session.device.noise.activeMode, .transparency)
        settle()
        XCTAssertEqual(headset.values[Cmd.ancOnGet], [0])
        XCTAssertEqual(headset.values[Cmd.transparencyOnGet], [1])
        XCTAssertEqual(session.device.noise.activeMode, .transparency)
        let sets = headset.received.filter { $0.command == Cmd.ancOnSet || $0.command == Cmd.transparencyOnSet }
        XCTAssertEqual(sets.map(\.command), [Cmd.ancOnSet, Cmd.transparencyOnSet])

        session.setNoiseMode(.off)
        settle()
        XCTAssertEqual(session.device.noise.activeMode, .off)
        XCTAssertEqual(headset.values[Cmd.transparencyOnGet], [0])
    }

    func testAntiWindAndAdaptiveWritesDoNotClobberEachOther() {
        connect()
        session.setAntiWind(.max)
        session.setAdaptiveANC(false)
        XCTAssertEqual(session.device.noise.antiWind, .max)
        XCTAssertEqual(session.device.noise.adaptiveANC, false)
        settle()
        XCTAssertEqual(headset.noiseModes, [1, 0, 0])
        XCTAssertEqual(session.device.noise.antiWind, .max)
        XCTAssertEqual(session.device.noise.adaptiveANC, false)
    }

    func testEqPresetWritesEveryBand() {
        connect()
        session.applyEqPreset(EqPreset.gains(named: "Pop")!)
        XCTAssertEqual(session.device.eqPreset, "Pop")
        settle()
        XCTAssertEqual(headset.bands, [0, 0xCE, 0, 50, 0])
        XCTAssertEqual(session.device.eqBands, [0, -5, 0, 5, 0])
    }

    func testEqBandIsClampedToDeviceRange() {
        connect()
        session.setEqBand(0, 12)
        settle()
        XCTAssertEqual(session.device.eqBands[0], 6)
        XCTAssertEqual(headset.bands[0], 60)
    }

    func testAutoPowerOffRoundTrip() {
        connect()
        session.setAutoPowerOff(seconds: 1800)
        settle()
        XCTAssertEqual(headset.powerOffSeconds, 1800)
        XCTAssertEqual(session.device.autoPowerOffSeconds, 1800)
        XCTAssertEqual(headset.received.first { $0.command == Cmd.timerSet }?.payload, [0, 0x07, 0x08])
    }

    func testPodcastModeOffRestoresPreviousAudioMode() {
        connect()
        XCTAssertEqual(session.device.audioMode, 1)
        session.setPodcastMode(true)
        settle()
        XCTAssertEqual(headset.values[Cmd.audioModeGet], [0, 2])
        session.setPodcastMode(false)
        settle()
        XCTAssertEqual(headset.values[Cmd.audioModeGet], [0, 1])
        XCTAssertEqual(session.device.audioMode, 1)
    }

    func testBatteryNotificationUpdatesState() {
        connect()
        headset.notify(Cmd.batteryNotif, [55])
        XCTAssertEqual(session.device.battery, 55)
    }

    func testUnpairRefreshesPairedList() {
        connect()
        session.deletePairedDevice(at: 1)
        let deadline = Date().addingTimeInterval(3)
        while session.device.pairedDevices.count != 1, Date() < deadline { spin(0.02) }
        XCTAssertEqual(session.device.pairedDevices.map(\.name), ["MacBook Pro"])
    }

    func testDisconnectClearsStateAndIgnoresControls() {
        connect()
        session.disconnect()
        XCTAssertFalse(session.isConnected)
        XCTAssertNil(session.device.battery)
        XCTAssertEqual(session.device, DeviceState())
        let count = headset.received.count
        session.setSmartPause(false)
        session.refreshAll()
        spin(0.02)
        XCTAssertEqual(headset.received.count, count)
        XCTAssertNil(session.device.smartPause)
    }

    func testLinkLossIsReported() {
        connect()
        headset.drop()
        XCTAssertFalse(session.isConnected)
        XCTAssertNotNil(session.lastError)
        XCTAssertNil(session.device.battery)
    }

    func testUnreachableHeadsetReportsError() {
        headset.unreachable = true
        session.refreshCandidates()
        session.connect(to: session.candidates[0])
        settle()
        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(session.lastError, "Couldn't reach the simulated headset.")
        XCTAssertNil(settings.string(forKey: "lastDeviceAddress"))
    }

    func testAutoConnectsToRememberedHeadset() {
        let first = makeSession()
        first.start()
        spin(0.02)
        XCTAssertFalse(first.isConnected || first.isConnecting)

        connect()
        session.disconnect()

        let second = makeSession()
        second.start()
        settle(second)
        XCTAssertTrue(second.isConnected)
        second.disconnect()

        let third = makeSession()
        third.autoConnect = false
        third.start()
        spin(0.02)
        XCTAssertFalse(third.isConnected || third.isConnecting)
        XCTAssertEqual(makeSession().autoConnect, false)
    }

    func testReconnectsWhenRememberedHeadsetAppears() {
        connect()
        session.disconnect()
        session.start()
        settle()
        session.disconnect()
        XCTAssertFalse(session.isConnected)

        directory.simulateConnection()
        let deadline = Date().addingTimeInterval(2)
        while !session.isConnected, Date() < deadline { spin() }
        XCTAssertTrue(session.isConnected)
    }

    func testMenuPanelIsCentredUnderTheStatusItemAndKeptOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1470, height: 923)
        let size = NSSize(width: 300, height: 400)
        let centred = StatusItemController.origin(below: NSRect(x: 900, y: 923, width: 60, height: 33), size: size, within: visible)
        XCTAssertEqual(centred, NSPoint(x: 780, y: 517))
        let nearRightEdge = StatusItemController.origin(below: NSRect(x: 1400, y: 923, width: 60, height: 33), size: size, within: visible)
        XCTAssertEqual(nearRightEdge.x, 1162)
        let nearLeftEdge = StatusItemController.origin(below: NSRect(x: 0, y: 923, width: 40, height: 33), size: size, within: visible)
        XCTAssertEqual(nearLeftEdge.x, 8)
    }

    func testEqualizerCurvePassesThroughBandsWithoutOvershoot() {
        let rect = CGRect(x: 0, y: 0, width: 600, height: 240)
        let positions: [CGFloat] = [0.13, 0.37, 0.53, 0.73, 0.87]
        for gains in [[0.0, 0, 3, 3, -1], [6, -6, 6, -6, 6], [-6, -6, -6, -6, -6], [5, -2, 0, 0, 0], [0, 0.5, 6, 5.5, -6]] {
            let curve = EqualizerCurve(gains: GainVector(values: gains), positions: positions, range: -6...6)
            let path = curve.path(in: rect)
            func y(_ gain: Double) -> CGFloat { CGFloat((6 - gain) / 12) * rect.height }
            let bounds = path.boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minY, y(gains.max()!) - 0.01, "\(gains)")
            XCTAssertLessThanOrEqual(bounds.maxY, y(gains.min()!) + 0.01, "\(gains)")
            XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
            XCTAssertEqual(bounds.maxX, rect.width, accuracy: 0.01)
            for (index, gain) in gains.enumerated() {
                let handle = CGPoint(x: positions[index] * rect.width, y: y(gain))
                XCTAssertTrue(path.strokedPath(StrokeStyle(lineWidth: 3)).contains(handle), "band \(index) of \(gains)")
            }
        }
    }

    func testGainVectorArithmetic() {
        let a = GainVector(values: [1, 2, 3])
        let b = GainVector(values: [3, 2, 1])
        XCTAssertEqual((a + b).values, [4, 4, 4])
        XCTAssertEqual((a - b).values, [-2, 0, 2])
        XCTAssertEqual((a + .zero).values, [1, 2, 3])
        var scaled = a
        scaled.scale(by: 0.5)
        XCTAssertEqual(scaled.values, [0.5, 1, 1.5])
        XCTAssertEqual(a.magnitudeSquared, 14)
    }

    func testRawFrameSender() {
        connect()
        XCTAssertFalse(session.sendRaw(hex: "ff0"))
        XCTAssertTrue(session.sendRaw(hex: "ff03 0000 0495 0603"))
        XCTAssertEqual(headset.received.last?.command, Cmd.batteryGet)
        settle()
    }
}
