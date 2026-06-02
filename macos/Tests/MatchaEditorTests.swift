import XCTest
import Foundation

/// Tests for the Swift wrapper around the Zig editor C ABI. These exercise
/// the FFI boundary — buffer mutation, selection / cursor, undo/redo,
/// save/load — which is where memory ownership bugs tend to surface.
final class MatchaEditorTests: XCTestCase {
    private var config: MatchaConfig!
    private var editor: MatchaEditor!

    override func setUp() {
        super.setUp()
        config = MatchaConfig()
        editor = MatchaEditor(config: config)
    }

    override func tearDown() {
        editor = nil
        config = nil
        super.tearDown()
    }

    // MARK: - Basic insert / content round-trip

    func testInsertAndGetContent() {
        editor.insert(text: "hello")
        XCTAssertEqual(editor.getContent(), "hello")
        XCTAssertEqual(editor.getCursorOffset(), 5)
    }

    func testInsertCJKBytePreservation() {
        editor.insert(text: "好こんにちは")
        XCTAssertEqual(editor.getContent(), "好こんにちは")
    }

    func testGetSelectionTextPreservesNonAsciiBytes() {
        editor.insert(text: "x好y")
        editor.setSelectionOffsets(start: 1, end: 4) // "好" is 3 bytes
        XCTAssertEqual(editor.getSelectionText(), "好")
    }

    // MARK: - replaceRange

    func testReplaceRangeInMiddle() {
        editor.insert(text: "abcdef")
        editor.replaceRange(start: 2, end: 4, text: "XY") // "abXYef"
        XCTAssertEqual(editor.getContent(), "abXYef")
    }

    func testReplaceRangeEmptyDelete() {
        editor.insert(text: "abc")
        editor.replaceRange(start: 1, end: 2, text: "")
        XCTAssertEqual(editor.getContent(), "ac")
    }

    func testReplaceRangeEmptyNoOpKeepsContentCacheFresh() {
        editor.insert(text: "abc")
        XCTAssertEqual(editor.getContentCached(), "abc")

        editor.replaceRange(start: 1, end: 1, text: "")

        XCTAssertEqual(editor.getContentCached(), "abc")
        XCTAssertEqual(editor.getCursorOffset(), 1)
    }

    func testContentCacheRefetchesAfterMutations() {
        editor.insert(text: "abc")
        XCTAssertEqual(editor.getContentCached(), "abc")

        editor.replaceRange(start: 1, end: 2, text: "X")
        XCTAssertEqual(editor.getContentCached(), "aXc")

        editor.newFile()
        XCTAssertEqual(editor.getContentCached(), "")
    }

    // MARK: - Selection offsets

    func testSelectionOffsetsRoundTrip() {
        editor.insert(text: "abcdef")
        editor.setSelectionOffsets(start: 2, end: 5)
        let range = editor.getSelectionOffsets()
        XCTAssertEqual(range?.lowerBound, 2)
        XCTAssertEqual(range?.upperBound, 5)
    }

    func testSelectionOffsetsNilWhenNoSelection() {
        editor.insert(text: "abc")
        editor.setCursorOffset(1)
        XCTAssertNil(editor.getSelectionOffsets())
    }

    // MARK: - Undo / Redo

    func testUndoRestoresEmpty() {
        editor.insert(text: "hello")
        editor.undo()
        XCTAssertEqual(editor.getContent(), "")
        XCTAssertEqual(editor.getCursorOffset(), 0)
    }

    func testRedoReappliesInsert() {
        editor.insert(text: "hello")
        editor.undo()
        editor.redo()
        XCTAssertEqual(editor.getContent(), "hello")
    }

    // MARK: - modified flag

    /// `info` is `@Published` and refreshed via DispatchQueue.main.async, so
    /// reads from a synchronous test need a brief run-loop turn to observe.
    private func waitForInfoUpdate() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    func testModifiedFlagTransitions() {
        waitForInfoUpdate()
        XCTAssertFalse(editor.info.modified)
        editor.insert(text: "x")
        waitForInfoUpdate()
        XCTAssertTrue(editor.info.modified)
        editor.undo()
        waitForInfoUpdate()
        XCTAssertFalse(editor.info.modified)
    }

    // MARK: - File round-trip

    func testSaveAsAndOpen() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcha-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }

        editor.insert(text: "round trip payload")
        XCTAssertTrue(editor.saveAs(path: tmp.path))
        waitForInfoUpdate()
        XCTAssertFalse(editor.info.modified)

        let onDisk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(onDisk, "round trip payload")

        let fresh = MatchaEditor(config: config)
        XCTAssertTrue(fresh.openFile(path: tmp.path))
        XCTAssertEqual(fresh.getContent(), "round trip payload")
    }

    func testOpenNonexistentFileFailsCleanly() {
        let path = "/tmp/matcha-this-path-must-not-exist-\(UUID().uuidString)"
        XCTAssertFalse(editor.openFile(path: path))
        // Editor must still be usable after a failed open.
        editor.insert(text: "x")
        XCTAssertEqual(editor.getContent(), "x")
    }

    // MARK: - Cursor offset

    func testSetCursorOffsetClampedToBufferLength() {
        editor.insert(text: "abc")
        editor.setCursorOffset(100) // past end — must not crash
        XCTAssertLessThanOrEqual(editor.getCursorOffset(), 3)
    }
}
