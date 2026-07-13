import XCTest
@testable import Domain

/// Contract tests for `SelectionReconcile.revealTab` — the *selection-follows-tab* rule behind
/// issue #100. It promises: only an **establishing** scope load (cold open / restore / explicit
/// repo-or-org selection) may switch the active tab to reveal the open item. A background/live data
/// refresh passes `establishing: false`, so it never moves the tab out from under the user. Don't
/// edit a contract test to make an implementation pass — if the contract is wrong, flag it.
final class SelectionReconcileTests: XCTestCase {

    // MARK: - Establishing may reveal the tab that holds the open item

    func testEstablishingRevealsTheIssuesTabForAnIssueNotInTheCurrentTab() {
        let tab = SelectionReconcile.revealTab(
            selectedId: "i1", currentTabHasSelected: false,
            selectedIsPR: false, selectedIsIssue: true, establishing: true)
        XCTAssertEqual(tab, .issues)
    }

    func testEstablishingRevealsThePRsTabForAPRNotInTheCurrentTab() {
        let tab = SelectionReconcile.revealTab(
            selectedId: "p1", currentTabHasSelected: false,
            selectedIsPR: true, selectedIsIssue: false, establishing: true)
        XCTAssertEqual(tab, .prs)
    }

    func testNoSwitchWhenTheOpenItemIsAlreadyInTheCurrentTab() {
        // Already visible on the current tab — nothing to reveal.
        let tab = SelectionReconcile.revealTab(
            selectedId: "p1", currentTabHasSelected: true,
            selectedIsPR: true, selectedIsIssue: false, establishing: true)
        XCTAssertNil(tab)
    }

    // MARK: - The #100 guard: a refresh must never move the tab

    func testRefreshNeverSwitchesTabEvenWhenTheOpenItemLivesInTheOtherTab() {
        // The user is on the PRs tab with an issue still selected; a data refresh lands. It must NOT
        // yank the view to the Issues tab.
        let tab = SelectionReconcile.revealTab(
            selectedId: "i1", currentTabHasSelected: false,
            selectedIsPR: false, selectedIsIssue: true, establishing: false)
        XCTAssertNil(tab)
    }

    // MARK: - Nothing to reveal

    func testNoSwitchWhenThereIsNoSelection() {
        let tab = SelectionReconcile.revealTab(
            selectedId: "", currentTabHasSelected: false,
            selectedIsPR: false, selectedIsIssue: false, establishing: true)
        XCTAssertNil(tab)
    }

    func testNoSwitchWhenTheOpenItemIsInNeitherList() {
        // e.g. the selected item was removed upstream — the fallback logic (in the caller) picks a
        // new selection; revealTab has no tab to move to.
        let tab = SelectionReconcile.revealTab(
            selectedId: "gone", currentTabHasSelected: false,
            selectedIsPR: false, selectedIsIssue: false, establishing: true)
        XCTAssertNil(tab)
    }

    func testPRsWinWhenAnIdSomehowResolvesToBothLists() {
        // Defensive: if an id appears in both lists, prefer PRs (mirrors the App layer's if/else-if
        // order). Not expected in practice — ids are unique — but pins the tie-break.
        let tab = SelectionReconcile.revealTab(
            selectedId: "x", currentTabHasSelected: false,
            selectedIsPR: true, selectedIsIssue: true, establishing: true)
        XCTAssertEqual(tab, .prs)
    }
}
