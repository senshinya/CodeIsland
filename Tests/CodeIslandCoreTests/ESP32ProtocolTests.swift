import XCTest
@testable import CodeIslandCore

final class ESP32ProtocolTests: XCTestCase {
    // MARK: - Source folding

    /// This fork's `SessionSnapshot.supportedSources` only contains claude/codex, so the
    /// upstream test that also folds gemini/cursor/trae/qoder/etc. would fail at the
    /// `normalizedSupportedSource` gate. Restrict the assertion to what this fork exposes;
    /// the unreachable enum cases still ship in `MascotID` because the protocol is the
    /// over-the-wire contract with the Buddy firmware.
    func testMascotIDFoldsSupportedSources() {
        XCTAssertEqual(MascotID(sourceName: "claude"), .claude)
        XCTAssertEqual(MascotID(sourceName: "codex"), .codex)
    }

    func testMascotIDReturnsNilForUnknownSource() {
        XCTAssertNil(MascotID(sourceName: nil))
        XCTAssertNil(MascotID(sourceName: ""))
        XCTAssertNil(MascotID(sourceName: "not-a-real-agent"))
    }

    // MARK: - Status mapping

    func testStatusCodeMapping() {
        XCTAssertEqual(MascotStatusCode(.idle).rawValue, 0)
        XCTAssertEqual(MascotStatusCode(.processing).rawValue, 1)
        XCTAssertEqual(MascotStatusCode(.running).rawValue, 2)
        XCTAssertEqual(MascotStatusCode(.waitingApproval).rawValue, 3)
        XCTAssertEqual(MascotStatusCode(.waitingQuestion).rawValue, 4)
    }

    // MARK: - Frame encoding

    func testEncodeMinimalFrameHasThreeBytes() {
        let frame = MascotFramePayload(mascot: .copilot, status: .waitingApproval)
        let data = frame.encode()
        XCTAssertEqual(Array(data), [4, 3, 0])
    }

    func testEncodeWithShortToolName() {
        let frame = MascotFramePayload(mascot: .claude, status: .running, toolName: "Bash")
        let data = frame.encode()
        XCTAssertEqual(data[0], 0)
        XCTAssertEqual(data[1], 2)
        XCTAssertEqual(data[2], 4)
        XCTAssertEqual(data.count, 3 + 4)
        XCTAssertEqual(String(data: data.subdata(in: 3..<data.count), encoding: .utf8), "Bash")
    }

    func testEncodeTruncatesToolNameToSeventeenBytes() {
        let long = "ThisIsAVeryLongToolName_WayPast17Bytes"
        let frame = MascotFramePayload(mascot: .gemini, status: .processing, toolName: long)
        let data = frame.encode()
        XCTAssertLessThanOrEqual(data.count, ESP32Protocol.maxFrameBytes)
        XCTAssertEqual(data[2], UInt8(ESP32Protocol.maxToolNameBytes))
        XCTAssertEqual(data.count, 3 + ESP32Protocol.maxToolNameBytes)
        // First 17 bytes of the UTF-8 must match.
        let expected = Array(long.utf8.prefix(ESP32Protocol.maxToolNameBytes))
        XCTAssertEqual(Array(data.suffix(ESP32Protocol.maxToolNameBytes)), expected)
    }

    func testEncodeEmptyToolNameIsTreatedAsNone() {
        let frame = MascotFramePayload(mascot: .kimi, status: .idle, toolName: "")
        XCTAssertEqual(Array(frame.encode()), [15, 0, 0])
    }

    func testEncodeBrightnessConfigFrame() {
        let frame = BuddyBrightnessPayload(percent: UInt8(64))
        XCTAssertEqual(Array(frame.encode()), [ESP32Protocol.brightnessFrameMarker, 64])
    }

    func testBrightnessConfigClampsToSupportedRange() {
        XCTAssertEqual(BuddyBrightnessPayload(percent: 1.0).percent, ESP32Protocol.minBrightnessPercent)
        XCTAssertEqual(BuddyBrightnessPayload(percent: 150.0).percent, ESP32Protocol.maxBrightnessPercent)
        XCTAssertEqual(BuddyBrightnessPayload(percent: Double.nan).percent, ESP32Protocol.defaultBrightnessPercent)
    }

    func testEncodeScreenOrientationConfigFrame() {
        XCTAssertEqual(
            Array(BuddyScreenOrientationPayload(orientation: .up).encode()),
            [ESP32Protocol.orientationFrameMarker, 0]
        )
        XCTAssertEqual(
            Array(BuddyScreenOrientationPayload(orientation: .down).encode()),
            [ESP32Protocol.orientationFrameMarker, 1]
        )
    }

    func testScreenOrientationDefaultsToUpForUnknownValues() {
        XCTAssertEqual(BuddyScreenOrientation(settingsValue: "down"), .down)
        XCTAssertEqual(BuddyScreenOrientation(settingsValue: "sideways"), .up)
        XCTAssertEqual(BuddyScreenOrientation(wireValue: 1), .down)
        XCTAssertEqual(BuddyScreenOrientation(wireValue: 7), .up)
    }

    func testConvenienceInitFromSourceString() {
        let frame = MascotFramePayload(source: "codex", status: .running, toolName: "Edit")
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.mascot, .codex)
        XCTAssertEqual(frame?.status, .running)
    }

    func testConvenienceInitReturnsNilForUnknownSource() {
        XCTAssertNil(MascotFramePayload(source: "bogus", status: .idle))
    }

    // MARK: - All 16 × 5 round-trip sanity

    func testAllMascotStatusCombinationsEncodeWithinLimits() {
        for mascot in MascotID.allCases {
            for statusRaw: UInt8 in 0...4 {
                let status = MascotStatusCode(rawValue: statusRaw)!
                let data = MascotFramePayload(mascot: mascot, status: status, toolName: "abc").encode()
                XCTAssertEqual(data[0], mascot.rawValue)
                XCTAssertEqual(data[1], statusRaw)
                XCTAssertEqual(data[2], 3)
                XCTAssertEqual(data.count, 6)
            }
        }
    }
}
