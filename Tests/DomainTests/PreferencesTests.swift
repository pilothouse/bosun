import XCTest
@testable import Domain

/// Contract tests for the `Preferences` value type. They describe what it promises outward —
/// its defaults, that it round-trips through Codable, that a payload missing keys decodes to
/// defaults (forward/backward compatibility), and that `windowAlpha` is clamped to a safe
/// range. Don't edit a contract test to make an implementation pass — if the contract is
/// wrong, flag it.
final class PreferencesTests: XCTestCase {

    func testDefaultsMatchTheInMemoryStartingState() {
        let p = Preferences.default
        XCTAssertEqual(p.themeKey, "operator")
        XCTAssertEqual(p.terminalHeight, 240)
        XCTAssertEqual(p.selectedConnId, "api-gateway")
        XCTAssertEqual(p.selectedItemId, "482")
        XCTAssertEqual(p.windowAlpha, 1.0)
    }

    func testCodableRoundTripPreservesEveryField() throws {
        let original = Preferences(
            themeKey: "nord",
            terminalHeight: 512,
            selectedConnId: "db-primary",
            selectedItemId: "991",
            windowAlpha: 0.75,
            sortField: "title",
            sortAscending: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testStatusFilterSelectionsRoundTrip() throws {
        let original = Preferences(prStates: ["open", "merged"], issueStates: ["open", "closed"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.prStates, ["open", "merged"])
        XCTAssertEqual(decoded.issueStates, ["open", "closed"])
        XCTAssertNil(Preferences.default.prStates, "never customized means open-only by default")
        XCTAssertNil(Preferences.default.issueStates)
    }

    func testDecodingPayloadMissingKeysFallsBackToDefaults() throws {
        // A payload written by an older build that only knew about the theme.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.themeKey, "carbon", "the present key is honored")
        XCTAssertEqual(decoded.terminalHeight, Preferences.default.terminalHeight)
        XCTAssertEqual(decoded.selectedConnId, Preferences.default.selectedConnId)
        XCTAssertEqual(decoded.selectedItemId, Preferences.default.selectedItemId)
        XCTAssertEqual(decoded.windowAlpha, Preferences.default.windowAlpha)
    }

    func testWindowAlphaIsClampedToSafeFloor() {
        XCTAssertEqual(Preferences(windowAlpha: 0.0).windowAlpha, 0.3,
                       "a fully transparent window would be unrecoverable")
        XCTAssertEqual(Preferences(windowAlpha: -5).windowAlpha, 0.3)
    }

    func testWindowAlphaIsClampedToCeiling() {
        XCTAssertEqual(Preferences(windowAlpha: 2.0).windowAlpha, 1.0)
    }

    func testWindowAlphaWithinRangeIsUnchanged() {
        XCTAssertEqual(Preferences(windowAlpha: 0.6).windowAlpha, 0.6)
    }

    func testDecodedOutOfRangeAlphaIsAlsoClamped() throws {
        let json = Data(#"{"windowAlpha":0.0}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.windowAlpha, 0.3, "clamping holds however a Preferences is built")
    }

    // MARK: - Opacity slider easing (issue #39)

    func testSliderEndpointsMapToFullRange() {
        XCTAssertEqual(Preferences.windowAlpha(forSliderPosition: 1.0), 1.0,
                       "the top of the slider is fully opaque")
        XCTAssertEqual(Preferences.windowAlpha(forSliderPosition: 0.0), Preferences.minAlpha,
                       accuracy: 1e-12, "the bottom of the slider is the most transparent we allow")
    }

    func testSliderAlphaIncreasesMonotonicallyWithPosition() {
        let a25 = Preferences.windowAlpha(forSliderPosition: 0.25)
        let a50 = Preferences.windowAlpha(forSliderPosition: 0.50)
        let a75 = Preferences.windowAlpha(forSliderPosition: 0.75)
        XCTAssertLessThan(a25, a50)
        XCTAssertLessThan(a50, a75)
    }

    func testSmallMoveFromOpaqueStaysSubtle() {
        // The core of #39: a ~10% drag down from fully opaque must barely change the window.
        XCTAssertGreaterThan(Preferences.windowAlpha(forSliderPosition: 0.9), 0.99,
                             "a small move near the top should be nearly invisible")
    }

    func testSliderPositionIsClampedToRange() {
        XCTAssertEqual(Preferences.windowAlpha(forSliderPosition: 2.0), 1.0,
                       "positions above 1 clamp to opaque")
        XCTAssertEqual(Preferences.windowAlpha(forSliderPosition: -1.0), Preferences.minAlpha,
                       accuracy: 1e-12, "positions below 0 clamp to the safe floor")
    }

    func testInversePositionEndpoints() {
        XCTAssertEqual(Preferences.sliderPosition(forWindowAlpha: 1.0), 1.0)
        XCTAssertEqual(Preferences.sliderPosition(forWindowAlpha: Preferences.minAlpha), 0.0,
                       accuracy: 1e-12)
        let belowFloor = Preferences.sliderPosition(forWindowAlpha: 0.0)
        XCTAssertGreaterThanOrEqual(belowFloor, 0.0, "an alpha under the floor still yields a valid position")
        XCTAssertLessThanOrEqual(belowFloor, 1.0)
    }

    func testCurveRoundTripsThroughItsInverse() {
        for alpha in [0.4, 0.6, 0.85, 1.0] {
            let roundTripped = Preferences.windowAlpha(
                forSliderPosition: Preferences.sliderPosition(forWindowAlpha: alpha))
            XCTAssertEqual(roundTripped, alpha, accuracy: 1e-9,
                           "position(alpha) then alpha(position) returns the original alpha")
        }
    }

    func testFollowedOrgsDefaultsToNil() {
        XCTAssertNil(Preferences.default.followedOrgs,
                     "an uncustomized list means 'show every org GitHub returns'")
    }

    func testFollowedOrgsRoundTripsThroughCodable() throws {
        let original = Preferences(followedOrgs: ["acme", "widgets"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.followedOrgs, ["acme", "widgets"])
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutFollowedOrgsFallsBackToNil() throws {
        // A payload written by a build before org-following existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.followedOrgs)
    }

    func testSelectedRepoKeyDefaultsToNil() {
        XCTAssertNil(Preferences.default.selectedRepoKey,
                     "no remembered repo means 'auto-select the first one'")
    }

    func testSelectedRepoKeyRoundTripsThroughCodable() throws {
        let original = Preferences(selectedRepoKey: "acme/widgets")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.selectedRepoKey, "acme/widgets")
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutSelectedRepoKeyFallsBackToNil() throws {
        // A payload written by a build before repo selection was remembered.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.selectedRepoKey)
    }

    func testTerminalBellBadgeDefaultsToOn() {
        XCTAssertTrue(Preferences.default.terminalBellBadge,
                      "the background-tab activity badge is opt-out (#74)")
    }

    func testTerminalBellBadgeRoundTripsThroughCodable() throws {
        let original = Preferences(terminalBellBadge: false)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertFalse(decoded.terminalBellBadge)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutTerminalBellBadgeFallsBackToOn() throws {
        // A payload written by a build before the badge setting existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertTrue(decoded.terminalBellBadge)
    }

    func testSelectedOrgIdDefaultsToEmpty() {
        XCTAssertEqual(Preferences.default.selectedOrgId, "",
                       "empty means a single repo (or nothing) was the active scope, not an org")
    }

    func testSelectedOrgIdRoundTripsThroughCodable() throws {
        let original = Preferences(selectedOrgId: "acme")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.selectedOrgId, "acme")
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutSelectedOrgIdFallsBackToEmpty() throws {
        // A payload written by a build before the aggregate org view was remembered.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.selectedOrgId, "")
    }

    func testOrgsScrollOffsetDefaultsToTop() {
        XCTAssertEqual(Preferences.default.orgsScrollOffset, 0, "the orgs panel starts at the top")
    }

    func testOrgsScrollOffsetRoundTripsThroughCodable() throws {
        let original = Preferences(orgsScrollOffset: 184.5)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.orgsScrollOffset, 184.5)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutOrgsScrollOffsetFallsBackToZero() throws {
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.orgsScrollOffset, 0)
    }

    func testOrgsListHeightDefaultsToThePreviousFixedCap() {
        XCTAssertEqual(Preferences.default.orgsListHeight, 268,
                       "the draggable orgs cap defaults to the old fixed height, so an upgrade is unchanged")
    }

    func testOrgsListHeightRoundTripsThroughCodable() throws {
        let original = Preferences(orgsListHeight: 412)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.orgsListHeight, 412)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutOrgsListHeightFallsBackToDefault() throws {
        // A payload written by a build before the orgs/issues splitter existed (#91).
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.orgsListHeight, Preferences.default.orgsListHeight)
    }

    func testSelectedTabAndGroupByDefaultToNil() {
        XCTAssertNil(Preferences.default.selectedTab, "nil means 'use the default tab'")
        XCTAssertNil(Preferences.default.groupBy, "nil means 'use the default View'")
    }

    func testSelectedTabAndGroupByRoundTripThroughCodable() throws {
        let original = Preferences(selectedTab: "issues", groupBy: "parent")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.selectedTab, "issues")
        XCTAssertEqual(decoded.groupBy, "parent")
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutTabOrGroupByFallsBackToNil() throws {
        // A payload written by a build before the tab/View were remembered.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.selectedTab)
        XCTAssertNil(decoded.groupBy)
    }

    func testRepoOrderingDefaultsToNil() {
        XCTAssertNil(Preferences.default.repoOrdering, "nil means 'order repos by name'")
    }

    func testRepoOrderingRoundTripsThroughCodable() throws {
        let original = Preferences(repoOrdering: "byOpenCount")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.repoOrdering, "byOpenCount")
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutRepoOrderingFallsBackToNil() throws {
        // A payload written by a build before repo ordering existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.repoOrdering)
    }

    func testSortDefaultsToDateDescending() {
        XCTAssertNil(Preferences.default.sortField, "nil means 'sort by date'")
        XCTAssertFalse(Preferences.default.sortAscending, "default is descending — newest first")
    }

    func testSortRoundTripsThroughCodable() throws {
        let original = Preferences(sortField: "number", sortAscending: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.sortField, "number")
        XCTAssertTrue(decoded.sortAscending)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutSortFallsBackToDefaults() throws {
        // A payload written by a build before list sorting existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.sortField)
        XCTAssertFalse(decoded.sortAscending)
    }

    func testOpenTabsDefaultToNil() {
        XCTAssertNil(Preferences.default.openTabs, "nil means 'seed a single local shell'")
        XCTAssertNil(Preferences.default.activeTabId)
    }

    func testOpenTabsRoundTripThroughCodable() throws {
        let tabs = [
            TerminalTabState(id: "tab-1", kind: .connection(id: "forge"), title: "Forge - API"),
            TerminalTabState(id: "tab-2", kind: .local, title: "zsh"),
        ]
        let original = Preferences(openTabs: tabs, activeTabId: "tab-2")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.openTabs, tabs)
        XCTAssertEqual(decoded.activeTabId, "tab-2")
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutOpenTabsFallsBackToNil() throws {
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.openTabs)
        XCTAssertNil(decoded.activeTabId)
    }

    func testPRChecksCollapsedDefaultsToFalse() {
        XCTAssertFalse(Preferences.default.prChecksCollapsed,
                       "the PR Actions list starts expanded")
    }

    func testPRChecksCollapsedRoundTripsThroughCodable() throws {
        let original = Preferences(prChecksCollapsed: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertTrue(decoded.prChecksCollapsed)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutPRChecksCollapsedFallsBackToFalse() throws {
        // A payload written by a build before the Actions section was collapsible.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertFalse(decoded.prChecksCollapsed)
    }

    func testSkipEmptyReposDefaultsToFalse() {
        XCTAssertFalse(Preferences.default.skipEmptyRepos,
                       "every repo shows until the user opts into hiding the empty ones")
    }

    func testSkipEmptyReposRoundTripsThroughCodable() throws {
        let original = Preferences(skipEmptyRepos: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertTrue(decoded.skipEmptyRepos)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutSkipEmptyReposFallsBackToFalse() throws {
        // A payload written by a build before the skip-empty-repos option existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertFalse(decoded.skipEmptyRepos)
    }

    func testSplitAxisDefaultsToNeverCustomized() {
        XCTAssertNil(Preferences.default.splitAxis,
                     "nil means never customized — the App layer falls back to the vertical split")
    }

    func testTerminalFractionDefaultsToSplitLayoutDefault() {
        XCTAssertEqual(Preferences.default.terminalFraction, SplitLayout.defaultFraction)
    }

    func testSplitStateRoundTripsThroughCodable() throws {
        let original = Preferences(splitAxis: "horizontal", terminalFraction: 0.6)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.splitAxis, "horizontal")
        XCTAssertEqual(decoded.terminalFraction, 0.6)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutSplitStateFallsBackToDefaults() throws {
        // A payload written by a build before the horizontal split existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertNil(decoded.splitAxis)
        XCTAssertEqual(decoded.terminalFraction, Preferences.default.terminalFraction)
    }

    func testTerminalLeadingDefaultsToFalse() {
        XCTAssertFalse(Preferences.default.terminalLeading,
                       "the terminal starts trailing — bottom/right — until the user swaps sides")
    }

    func testTerminalLeadingRoundTripsThroughCodable() throws {
        let original = Preferences(terminalLeading: true)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertTrue(decoded.terminalLeading)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutTerminalLeadingFallsBackToFalse() throws {
        // A payload written by a build before the swap-sides option existed.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertFalse(decoded.terminalLeading)
    }

    func testUIZoomDefaultsToOneHundredPercent() {
        XCTAssertEqual(Preferences.default.uiZoomPercent, 100,
                       "an upgrade starts at 1:1 zoom, unchanged")
    }

    func testUIZoomRoundTripsThroughCodable() throws {
        let original = Preferences(uiZoomPercent: 130)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)

        XCTAssertEqual(decoded.uiZoomPercent, 130)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingPayloadWithoutUIZoomFallsBackToOneHundred() throws {
        // A payload written by a build before the zoom feature existed must open at 1:1.
        let json = Data(#"{"themeKey":"carbon"}"#.utf8)

        let decoded = try JSONDecoder().decode(Preferences.self, from: json)

        XCTAssertEqual(decoded.uiZoomPercent, 100)
    }
}
