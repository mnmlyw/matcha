import XCTest
import AppKit

/// TabManager is @MainActor and XCTest runs the test thread on main, so we
/// can drive it directly. We avoid the modal-dialog code paths (closeTab on
/// modified tabs, reviewAllUnsavedInteractively) since those require UI.
@MainActor
final class TabManagerTests: XCTestCase {

    func testInitHasOneEmptyTab() {
        let tm = TabManager()
        XCTAssertEqual(tm.tabs.count, 1)
        XCTAssertEqual(tm.activeIndex, 0)
        XCTAssertEqual(tm.activeTab?.title, "Untitled")
        XCTAssertFalse(tm.activeTab!.isModified)
    }

    func testNewTabAppendsAndActivates() {
        let tm = TabManager()
        tm.newTab()
        XCTAssertEqual(tm.tabs.count, 2)
        XCTAssertEqual(tm.activeIndex, 1)
    }

    func testCloseUnmodifiedTabRemovesIt() {
        let tm = TabManager()
        tm.newTab()
        tm.newTab() // 3 tabs total
        XCTAssertEqual(tm.tabs.count, 3)

        tm.closeTab(at: 1)
        XCTAssertEqual(tm.tabs.count, 2)
    }

    func testCloseLastUnmodifiedTabResetsInsteadOfRemoving() {
        // The single-tab case is special — closing it shouldn't leave the
        // user with zero tabs; it should reset to a new empty buffer.
        let tm = TabManager()
        XCTAssertEqual(tm.tabs.count, 1)
        let originalId = tm.tabs[0].id
        tm.closeTab(at: 0)
        XCTAssertEqual(tm.tabs.count, 1)
        // Same Tab struct (no removal), buffer was reset by newFile().
        XCTAssertEqual(tm.tabs[0].id, originalId)
    }

    func testSelectTabUpdatesActiveIndex() {
        let tm = TabManager()
        tm.newTab()
        tm.newTab()
        XCTAssertEqual(tm.activeIndex, 2)
        tm.selectTab(at: 0)
        XCTAssertEqual(tm.activeIndex, 0)
    }

    func testSelectTabIgnoresOutOfRange() {
        let tm = TabManager()
        let before = tm.activeIndex
        tm.selectTab(at: 99)
        XCTAssertEqual(tm.activeIndex, before)
        tm.selectTab(at: -1)
        XCTAssertEqual(tm.activeIndex, before)
    }

    func testMoveTabReordersAndPreservesActive() {
        let tm = TabManager()
        tm.newTab()
        tm.newTab()
        // Tabs: [t0, t1, t2], active = 2
        let originalIds = tm.tabs.map { $0.id }
        let activeId = tm.tabs[tm.activeIndex].id

        tm.moveTab(from: 0, to: 2)
        XCTAssertEqual(tm.tabs.map { $0.id }, [originalIds[1], originalIds[2], originalIds[0]])
        // The previously-active tab should still be active by ID.
        XCTAssertEqual(tm.tabs[tm.activeIndex].id, activeId)
    }

    func testSelectNextTabWrapsAround() {
        let tm = TabManager()
        tm.newTab()
        tm.newTab() // active = 2
        tm.selectNextTab()
        XCTAssertEqual(tm.activeIndex, 0)
        tm.selectNextTab()
        XCTAssertEqual(tm.activeIndex, 1)
    }

    func testSelectPreviousTabWrapsAround() {
        let tm = TabManager()
        tm.newTab() // active = 1
        tm.selectPreviousTab()
        XCTAssertEqual(tm.activeIndex, 0)
        tm.selectPreviousTab()
        XCTAssertEqual(tm.activeIndex, 1)
    }
}
