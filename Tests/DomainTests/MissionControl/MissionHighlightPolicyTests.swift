import XCTest
@testable import Domain

/// Contract tests for `MissionHighlightPolicy` (#103): how a tile looks when "Highlight activity"
/// is on, and that it looks exactly like before when the toggle is off.
final class MissionHighlightPolicyTests: XCTestCase {

    private let everyActivity: [MissionTileActivity] = [.idle, .working, .attention, .done]
    private let plain = MissionTileTreatment(border: .standard, dimmed: false)

    func testOffLeavesEveryTileAsToday() {
        for activity in everyActivity {
            for focused in [true, false] {
                XCTAssertEqual(MissionHighlightPolicy.treatment(activity: activity, focused: focused, enabled: false),
                               plain, "\(activity) focused=\(focused)")
            }
        }
    }

    func testWorkingTileGetsTheWorkingBorder() {
        XCTAssertEqual(MissionHighlightPolicy.treatment(activity: .working, focused: false, enabled: true),
                       MissionTileTreatment(border: .working, dimmed: false))
    }

    func testDoneTileGetsTheDoneBorder() {
        XCTAssertEqual(MissionHighlightPolicy.treatment(activity: .done, focused: false, enabled: true),
                       MissionTileTreatment(border: .done, dimmed: false))
    }

    func testUnfocusedIdleTileIsDimmed() {
        XCTAssertEqual(MissionHighlightPolicy.treatment(activity: .idle, focused: false, enabled: true),
                       MissionTileTreatment(border: .standard, dimmed: true))
    }

    func testFocusedTileIsNeverDimmed() {
        // You are typing into it; dimming it would hide your own work.
        XCTAssertFalse(MissionHighlightPolicy.treatment(activity: .idle, focused: true, enabled: true).dimmed)
    }

    func testAttentionKeepsItsCurrentLook() {
        // "Needs you" already has its amber dot and banner; the highlight doesn't restyle it.
        XCTAssertEqual(MissionHighlightPolicy.treatment(activity: .attention, focused: false, enabled: true), plain)
    }
}
