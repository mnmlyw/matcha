import Foundation
import MatchaKit

/// Swift wrapper around the Zig editor core (matcha_editor_t).
class MatchaEditor: ObservableObject {
    private final class WeakEditorRef {
        weak var value: MatchaEditor?
    }

    private static let activeEditorRef = WeakEditorRef()

    private(set) var handle: matcha_editor_t?
    let config: MatchaConfig

    @Published var info: EditorInfo = EditorInfo()
    @Published var lastError: String? = nil
    private(set) var currentError: String? = nil

    struct EditorInfo {
        var cursorLine: UInt32 = 1
        var cursorCol: UInt32 = 1
        var totalLines: UInt32 = 1
        var modified: Bool = false
        var filename: String? = nil
    }

    init(config: MatchaConfig) {
        self.config = config
        self.handle = matcha_editor_new(config.handle)
    }

    deinit {
        if let h = handle {
            matcha_editor_free(h)
        }
    }

    // MARK: - Error Feedback

    func getLastError() -> String? {
        guard let h = handle else { return nil }
        guard let cStr = matcha_editor_get_last_error(h) else { return nil }
        let str = String(cString: cStr)
        matcha_editor_clear_error(h)
        return str
    }

    static var activeEditor: MatchaEditor? {
        activeEditorRef.value
    }

    func markActive() {
        MatchaEditor.activeEditorRef.value = self
    }

    // MARK: - File I/O

    func newFile() {
        guard let h = handle else { return }
        matcha_editor_new_file(h)
        updateInfo()
    }

    func openFile(path: String) -> Bool {
        guard let h = handle else { return false }
        let result = matcha_editor_open_file(h, path)
        updateInfo()
        return result
    }

    func save() -> Bool {
        guard let h = handle else { return false }
        let result = matcha_editor_save(h)
        updateInfo()
        return result
    }

    func saveAs(path: String) -> Bool {
        guard let h = handle else { return false }
        let result = matcha_editor_save_as(h, path)
        updateInfo()
        return result
    }

    // MARK: - Editing

    func insert(text: String) {
        guard let h = handle else { return }
        text.withCString { ptr in
            matcha_editor_insert(h, ptr, UInt32(text.utf8.count))
        }
        updateInfo()
    }

    func deleteBackward() {
        guard let h = handle else { return }
        matcha_editor_delete_backward(h)
        updateInfo()
    }

    func deleteForward() {
        guard let h = handle else { return }
        matcha_editor_delete_forward(h)
        updateInfo()
    }

    func deleteWordBackward() {
        guard let h = handle else { return }
        matcha_editor_delete_word_backward(h)
        updateInfo()
    }

    func deleteWordForward() {
        guard let h = handle else { return }
        matcha_editor_delete_word_forward(h)
        updateInfo()
    }

    func newline() {
        guard let h = handle else { return }
        matcha_editor_newline(h)
        updateInfo()
    }

    func insertTab() {
        guard let h = handle else { return }
        matcha_editor_insert_tab(h)
        updateInfo()
    }

    func dedent() {
        guard let h = handle else { return }
        matcha_editor_dedent(h)
        updateInfo()
    }

    func toggleComment() {
        guard let h = handle else { return }
        matcha_editor_toggle_comment(h)
        updateInfo()
    }

    func duplicateLine() {
        guard let h = handle else { return }
        matcha_editor_duplicate_line(h)
        updateInfo()
    }

    func moveLineUp() {
        guard let h = handle else { return }
        matcha_editor_move_line_up(h)
        updateInfo()
    }

    func moveLineDown() {
        guard let h = handle else { return }
        matcha_editor_move_line_down(h)
        updateInfo()
    }

    // MARK: - Movement

    func moveLeft() { guard let h = handle else { return }; matcha_editor_move_left(h); updateInfo() }
    func moveRight() { guard let h = handle else { return }; matcha_editor_move_right(h); updateInfo() }
    func moveUp() { guard let h = handle else { return }; matcha_editor_move_up(h); updateInfo() }
    func moveDown() { guard let h = handle else { return }; matcha_editor_move_down(h); updateInfo() }
    func moveLineStart() { guard let h = handle else { return }; matcha_editor_move_line_start(h); updateInfo() }
    func moveLineEnd() { guard let h = handle else { return }; matcha_editor_move_line_end(h); updateInfo() }
    func moveStart() { guard let h = handle else { return }; matcha_editor_move_start(h); updateInfo() }
    func moveEnd() { guard let h = handle else { return }; matcha_editor_move_end(h); updateInfo() }
    func goToLine(_ line: UInt32) { guard let h = handle else { return }; matcha_editor_go_to_line(h, line); updateInfo() }
    func movePageUp() { guard let h = handle else { return }; matcha_editor_move_page_up(h); updateInfo() }
    func movePageDown() { guard let h = handle else { return }; matcha_editor_move_page_down(h); updateInfo() }
    func moveWordLeft() { guard let h = handle else { return }; matcha_editor_move_word_left(h); updateInfo() }
    func moveWordRight() { guard let h = handle else { return }; matcha_editor_move_word_right(h); updateInfo() }

    // MARK: - Selection

    func selectLeft() { guard let h = handle else { return }; matcha_editor_select_left(h); updateInfo() }
    func selectRight() { guard let h = handle else { return }; matcha_editor_select_right(h); updateInfo() }
    func selectUp() { guard let h = handle else { return }; matcha_editor_select_up(h); updateInfo() }
    func selectDown() { guard let h = handle else { return }; matcha_editor_select_down(h); updateInfo() }
    func selectLineStart() { guard let h = handle else { return }; matcha_editor_select_line_start(h); updateInfo() }
    func selectLineEnd() { guard let h = handle else { return }; matcha_editor_select_line_end(h); updateInfo() }
    func selectAll() { guard let h = handle else { return }; matcha_editor_select_all(h); updateInfo() }
    func selectStart() { guard let h = handle else { return }; matcha_editor_select_start(h); updateInfo() }
    func selectEnd() { guard let h = handle else { return }; matcha_editor_select_end(h); updateInfo() }
    func selectWordLeft() { guard let h = handle else { return }; matcha_editor_select_word_left(h); updateInfo() }
    func selectWordRight() { guard let h = handle else { return }; matcha_editor_select_word_right(h); updateInfo() }

    // MARK: - Clipboard

    func getSelectionText() -> String? {
        guard let h = handle else { return nil }
        guard let cStr = matcha_editor_get_selection_text(h) else { return nil }
        let str = String(cString: cStr)
        matcha_editor_free_string(cStr)
        return str
    }

    func getContent() -> String? {
        guard let h = handle else { return nil }
        var len: UInt32 = 0
        guard let ptr = matcha_editor_get_content(h, &len) else { return nil }
        let utf8Ptr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: utf8Ptr, count: Int(len))
        let content = String(decoding: buffer, as: UTF8.self)
        matcha_editor_free_string(ptr)
        return content
    }

    func getSelectionOffsets() -> Range<UInt32>? {
        guard let h = handle else { return nil }
        var start: UInt32 = 0
        var end: UInt32 = 0
        guard matcha_editor_get_selection_offsets(h, &start, &end) else { return nil }
        return start..<end
    }

    func getCursorOffset() -> UInt32 {
        guard let h = handle else { return 0 }
        return matcha_editor_get_cursor_offset(h)
    }

    func paste(text: String) {
        guard let h = handle else { return }
        text.withCString { ptr in
            matcha_editor_paste(h, ptr, UInt32(text.utf8.count))
        }
        updateInfo()
    }

    func replaceRange(start: UInt32, end: UInt32, text: String) {
        guard let h = handle else { return }
        text.withCString { ptr in
            matcha_editor_replace_range(h, start, end, ptr, UInt32(text.utf8.count))
        }
        updateInfo()
    }

    func setCursorOffset(_ pos: UInt32) {
        guard let h = handle else { return }
        matcha_editor_set_cursor_offset(h, pos)
        updateInfo()
    }

    func setSelectionOffsets(start: UInt32, end: UInt32) {
        guard let h = handle else { return }
        matcha_editor_set_selection_offsets(h, start, end)
        updateInfo()
    }

    // MARK: - Word Completion

    func getCompletions() -> (words: [String], prefixLen: Int)? {
        guard let h = handle else { return nil }
        var prefixLen: UInt32 = 0
        guard let cStr = matcha_editor_get_completions(h, &prefixLen) else { return nil }
        let str = String(cString: cStr)
        matcha_free_string(cStr)
        let words = str.split(separator: "\n").map(String.init)
        guard !words.isEmpty else { return nil }
        return (words: words, prefixLen: Int(prefixLen))
    }

    // MARK: - Undo/Redo

    func undo() { guard let h = handle else { return }; matcha_editor_undo(h); updateInfo() }
    func redo() { guard let h = handle else { return }; matcha_editor_redo(h); updateInfo() }

    // MARK: - Viewport

    func setViewport(width: UInt32, height: UInt32, cellWidth: Float, cellHeight: Float) {
        guard let h = handle else { return }
        matcha_editor_set_viewport(h, width, height, cellWidth, cellHeight)
    }

    func setWideCellWidth(_ width: Float) {
        guard let h = handle else { return }
        matcha_editor_set_wide_cell_width(h, width)
    }

    func setHangulCellWidth(_ width: Float) {
        guard let h = handle else { return }
        matcha_editor_set_hangul_cell_width(h, width)
    }

    func scroll(dx: Float, dy: Float) {
        guard let h = handle else { return }
        matcha_editor_scroll(h, dx, dy)
    }

    func click(x: Float, y: Float, extend: Bool) {
        guard let h = handle else { return }
        matcha_editor_click(h, x, y, extend)
        updateInfo()
    }

    func doubleClick(x: Float, y: Float) {
        guard let h = handle else { return }
        matcha_editor_double_click(h, x, y)
        updateInfo()
    }

    func tripleClick(x: Float, y: Float) {
        guard let h = handle else { return }
        matcha_editor_triple_click(h, x, y)
        updateInfo()
    }

    func hitTestOffset(x: Float, y: Float) -> UInt32 {
        guard let h = handle else { return 0 }
        return matcha_editor_hit_test_offset(h, x, y)
    }

    func rectForOffset(_ pos: UInt32) -> CGRect? {
        guard let h = handle else { return nil }
        var x: Float = 0
        var y: Float = 0
        var w: Float = 0
        var hgt: Float = 0
        guard matcha_editor_get_rect_for_offset(h, pos, &x, &y, &w, &hgt) else { return nil }
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(hgt))
    }

    func getScrollY() -> Float {
        guard let h = handle else { return 0 }
        return matcha_editor_get_scroll_y(h)
    }

    // MARK: - Find & Replace

    func findNext(query: String, caseSensitive: Bool = true, wholeWord: Bool = false) -> Bool {
        guard let h = handle else { return false }
        return query.withCString { ptr in
            let result = matcha_editor_find_next_with_options(h, ptr, UInt32(query.utf8.count),
                                                              caseSensitive, wholeWord)
            updateInfo()
            return result
        }
    }

    func findPrev(query: String, caseSensitive: Bool = true, wholeWord: Bool = false) -> Bool {
        guard let h = handle else { return false }
        return query.withCString { ptr in
            let result = matcha_editor_find_prev_with_options(h, ptr, UInt32(query.utf8.count),
                                                              caseSensitive, wholeWord)
            updateInfo()
            return result
        }
    }

    func replaceNext(query: String, replacement: String,
                     caseSensitive: Bool = true, wholeWord: Bool = false) -> Bool
    {
        guard let h = handle else { return false }
        return query.withCString { qPtr in
            replacement.withCString { rPtr in
                let result = matcha_editor_replace_next_with_options(
                    h,
                    qPtr, UInt32(query.utf8.count),
                    rPtr, UInt32(replacement.utf8.count),
                    caseSensitive, wholeWord
                )
                updateInfo()
                return result
            }
        }
    }

    func replaceAll(query: String, replacement: String,
                    caseSensitive: Bool = true, wholeWord: Bool = false) -> UInt32
    {
        guard let h = handle else { return 0 }
        return query.withCString { qPtr in
            replacement.withCString { rPtr in
                let result = matcha_editor_replace_all_with_options(
                    h,
                    qPtr, UInt32(query.utf8.count),
                    rPtr, UInt32(replacement.utf8.count),
                    caseSensitive, wholeWord
                )
                updateInfo()
                return result
            }
        }
    }

    // MARK: - Render

    func prepareRender() {
        guard let h = handle else { return }
        matcha_editor_prepare_render(h)
    }

    func getCells() -> UnsafeBufferPointer<matcha_render_cell_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_cells(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getCursors() -> UnsafeBufferPointer<matcha_render_cursor_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_cursors(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getSelections() -> UnsafeBufferPointer<matcha_render_rect_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_selections(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getGutterRows() -> UnsafeBufferPointer<matcha_render_rect_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_line_number_cells(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getLineNumberLabels() -> UnsafeBufferPointer<matcha_render_line_number_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_line_number_labels(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getBracketHighlights() -> UnsafeBufferPointer<matcha_render_rect_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_bracket_highlights(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    func getClusterData() -> UnsafeBufferPointer<UInt8> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var len: UInt32 = 0
        guard let ptr = matcha_editor_get_cluster_data(h, &len) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(len))
    }

    // MARK: - Info

    func updateInfo() {
        guard let h = handle else { return }
        let cInfo = matcha_editor_get_info(h)
        // filename is a borrowed pointer (valid until next editor mutation), no need to free
        let fname: String? = cInfo.filename.map { String(cString: $0) }
        let error = getLastError()
        currentError = error
        DispatchQueue.main.async { [weak self] in
            self?.info = EditorInfo(
                cursorLine: cInfo.cursor_line,
                cursorCol: cInfo.cursor_col,
                totalLines: cInfo.total_lines,
                modified: cInfo.modified,
                filename: fname
            )
            self?.lastError = error
        }
    }
}
