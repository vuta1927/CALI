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
        XCTAssertEqual(COAMIColorToken.flame.rawValue, 0xFF7A2F)
        XCTAssertEqual(COAMIColorToken.orange.rawValue, 0xFC4C02)
        XCTAssertEqual(COAMIColorToken.ember.rawValue, 0xE83F00)
        XCTAssertEqual(COAMIColorToken.blue.rawValue, 0x0077C8)
        XCTAssertEqual(COAMIColorToken.ink.rawValue, 0x1A1206)
        XCTAssertEqual(COAMIColorToken.cream.rawValue, 0xFFF3EC)
    }

    func testSemanticPaletteAdaptsWithoutChangingBrandIdentity() {
        let light = COAMIThemePalette.palette(for: .light)
        let dark = COAMIThemePalette.palette(for: .dark)

        XCTAssertEqual(light.canvas, 0xF5F5F7)
        XCTAssertEqual(light.text, 0x242428)
        XCTAssertEqual(dark.canvas, 0x121214)
        XCTAssertEqual(dark.text, 0xF2F2F5)
        XCTAssertEqual(light.accent, COAMIColorToken.orange.rawValue)
        XCTAssertEqual(light.accentInk, 0xC43C00)
        XCTAssertEqual(dark.accent, 0xFF6A2B)
    }

    /// WCAG 2.x contrast: orange text must reach 4.5:1 on canvas and surface in both modes,
    /// and on-accent ink must reach 4.5:1 on the accent fill.
    func testAccentContrastMeetsWCAG() {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ v: UInt32) -> Double {
                let c = Double(v) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
        }
        func ratio(_ a: UInt32, _ b: UInt32) -> Double {
            let (l1, l2) = (luminance(a), luminance(b))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        for palette in [COAMIThemePalette.palette(for: .light), COAMIThemePalette.palette(for: .dark)] {
            XCTAssertGreaterThanOrEqual(ratio(palette.accentInk, palette.canvas), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(palette.accentInk, palette.surface), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(COAMIColorToken.ink.rawValue, palette.accent), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(palette.secondary, palette.surface), 4.5)
        }
    }

    func testReduceTransparencyAlwaysUsesOpaqueSurfaces() {
        XCTAssertFalse(COAMIEffectPolicy.usesMaterial(reduceTransparency: true))
        XCTAssertTrue(COAMIEffectPolicy.usesMaterial(reduceTransparency: false))
    }
}
