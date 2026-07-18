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

    // MARK: - UTF-16 <-> byte offset conversion (IME position queries)

    func testUTF16OffsetRoundTripsThroughASCII() {
        editor.insert(text: "hello world")
        XCTAssertEqual(editor.utf16Offset(fromBytePos: 5), 5)
        XCTAssertEqual(editor.bytePos(fromUTF16Offset: 5), 5)
    }

    func testUTF16OffsetCountsAstralCodepointsAsTwoUnits() {
        // U+1F600 is 4 UTF-8 bytes and a UTF-16 surrogate pair (2 units).
        editor.insert(text: "a\u{1F600}b")
        XCTAssertEqual(editor.utf16Offset(fromBytePos: 0), 0)
        XCTAssertEqual(editor.utf16Offset(fromBytePos: 1), 1) // just before the emoji
        XCTAssertEqual(editor.utf16Offset(fromBytePos: 5), 3) // just before "b"
        XCTAssertEqual(editor.bytePos(fromUTF16Offset: 3), 5)
    }

    /// Regression test for the IME byte-offset corruption bug: computing
    /// byte offsets from a *decoded* Swift String (which substitutes
    /// invalid UTF-8 with U+FFFD and re-encodes to a different byte length)
    /// desyncs from the real buffer and can corrupt the document when an
    /// IME writes back using that offset. `utf16Offset`/`bytePos` are
    /// backed by an ABI call that walks the raw buffer bytes directly, so
    /// every real byte offset must round-trip through UTF-16 space exactly,
    /// even when the buffer contains invalid UTF-8 that `getContent()`
    /// would have to lossily substitute.
    ///
    /// A Swift `String` can never itself hold invalid UTF-8 (any attempt to
    /// build one already substitutes U+FFFD before it reaches the editor),
    /// so the only way to get real invalid UTF-8 into the buffer through
    /// the public API is to load a file containing raw bytes -- which is
    /// also the realistic scenario this bug affects (opening a file with
    /// mixed/foreign encoding and then using an IME on it).
    func testUTF16OffsetRoundTripsExactlyOnInvalidUTF8() throws {
        let invalidUTF8: [UInt8] = [0x61, 0x80, 0x81, 0x62] // "a" + 2 lone continuation bytes + "b"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("matcha-invalid-utf8-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(invalidUTF8).write(to: tmp)

        XCTAssertTrue(editor.openFile(path: tmp.path))

        // The buffer must have kept the original 4 raw bytes, not the
        // length a lossy decode-to-String-and-back would produce (each
        // U+FFFD substitution re-encodes to 3 UTF-8 bytes, so a naive
        // round-trip would see 8 bytes here instead of 4). setCursorOffset
        // clamps to the real buffer length, so this reads it without going
        // through the lossy getContent() decode.
        editor.setCursorOffset(.max)
        XCTAssertEqual(editor.getCursorOffset(), 4)

        for pos: UInt32 in 0...4 {
            let utf16 = editor.utf16Offset(fromBytePos: pos)
            XCTAssertEqual(editor.bytePos(fromUTF16Offset: utf16), pos, "byte offset \(pos) did not round-trip")
        }
    }
}
