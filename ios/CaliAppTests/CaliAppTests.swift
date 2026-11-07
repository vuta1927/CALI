import XCTest
@testable import CaliApp

final class BuildInfoTests: XCTestCase {
    func testReadsVersionBuildAndSHAFromInfoDictionary() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "7",
            "CaliBuildSHA": "0123456789abcdef0123456789abcdef01234567",
        ])

        XCTAssertEqual(info.version, "0.1.0")
        XCTAssertEqual(info.build, "7")
        XCTAssertEqual(info.sha, "0123456789abcdef0123456789abcdef01234567")
    }

    func testMissingOrEmptyValuesFallBackToUnknown() {
        let info = BuildInfo(infoDictionary: ["CFBundleVersion": "", "CaliBuildSHA": 42])

        XCTAssertEqual(info.version, BuildInfo.unknown)
        XCTAssertEqual(info.build, BuildInfo.unknown)
        XCTAssertEqual(info.sha, BuildInfo.unknown)
        XCTAssertEqual(BuildInfo(infoDictionary: nil).sha, BuildInfo.unknown)
    }
}

final class WorkoutContentStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(phase: WorkoutAttributes.Phase, endOffset: TimeInterval) -> WorkoutAttributes.ContentState {
        WorkoutAttributes.ContentState(
            sessionId: UUID(),
            exerciseShortName: "Tuck Planche",
            phase: phase,
            setIndex: 2,
            setCount: 4,
            targetSeconds: 12,
            phaseStartUtc: start,
            phaseEndUtc: start.addingTimeInterval(endOffset),
            pausedTimeUtc: nil,
            revision: 1
        )
    }

    func testCountdownIntervalSpansPhaseStartToEnd() {
        let interval = state(phase: .exercising, endOffset: 12).countdownInterval

        XCTAssertEqual(interval?.lowerBound, start)
        XCTAssertEqual(interval?.upperBound, start.addingTimeInterval(12))
    }

    func testCountdownIntervalIsNeverInverted() {
        // End before start (bad snapshot / clock jump) must not trap in `a...b`.
        let interval = state(phase: .resting, endOffset: -30).countdownInterval

        XCTAssertEqual(interval?.lowerBound, start)
        XCTAssertEqual(interval?.upperBound, start)
    }

    func testPhasesWithoutCountdownHaveNoInterval() {
        for phase in [WorkoutAttributes.Phase.ready, .awaitingResult, .reviewingSummary, .completed, .abandoned] {
            XCTAssertNil(state(phase: phase, endOffset: 12).countdownInterval, "\(phase)")
        }
    }

    func testPhaseRawValuesMatchContractEnum() {
        // contracts/entity-payloads.schema.json -> session.phase
        let contract = ["ready", "pre_countdown", "exercising", "awaiting_result", "resting",
                        "paused", "reviewing_summary", "completed", "abandoned"]

        XCTAssertEqual(WorkoutAttributes.Phase.allCases.map(\.rawValue), contract)
    }
}

final class COAMIThemeTests: XCTestCase {
    func testBrandTokensMatchTheHandoff() {
        XCTAssertEqual(COAMIColorToken.mint.rawValue, 0x2FF6C4)
        XCTAssertEqual(COAMIColorToken.teal.rawValue, 0x00D4C6)
        XCTAssertEqual(COAMIColorToken.aqua.rawValue, 0x00A7E1)
        XCTAssertEqual(COAMIColorToken.navy.rawValue, 0x0B2742)
        XCTAssertEqual(COAMIColorToken.ice.rawValue, 0xEAF7FF)
    }

    func testSemanticPaletteAdaptsWithoutChangingBrandIdentity() {
        let light = COAMIThemePalette.palette(for: .light)
        let dark = COAMIThemePalette.palette(for: .dark)

        XCTAssertEqual(light.canvas, 0xF4FAFD)
        XCTAssertEqual(light.text, COAMIColorToken.navy.rawValue)
        XCTAssertEqual(dark.canvas, 0x071927)
        XCTAssertEqual(dark.text, COAMIColorToken.ice.rawValue)
        XCTAssertEqual(light.accent, COAMIColorToken.teal.rawValue)
        XCTAssertEqual(dark.accent, COAMIColorToken.mint.rawValue)
    }

    func testReduceTransparencyAlwaysUsesOpaqueSurfaces() {
        XCTAssertFalse(COAMIEffectPolicy.usesMaterial(reduceTransparency: true))
        XCTAssertTrue(COAMIEffectPolicy.usesMaterial(reduceTransparency: false))
    }
}
