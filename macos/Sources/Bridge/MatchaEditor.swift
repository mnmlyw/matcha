import Foundation
import MatchaKit

/// Swift wrapper around the Zig editor core (matcha_editor_t).
class MatchaEditor: ObservableObject {
    private(set) var handle: matcha_editor_t?
    private let config: MatchaConfig

    @Published var info: EditorInfo = EditorInfo()

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

    // MARK: - File I/O

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

    func newline() {
        guard let h = handle else { return }
        matcha_editor_newline(h)
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

    func paste(text: String) {
        guard let h = handle else { return }
        text.withCString { ptr in
            matcha_editor_paste(h, ptr, UInt32(text.utf8.count))
        }
        updateInfo()
    }

    // MARK: - Undo/Redo

    func undo() { guard let h = handle else { return }; matcha_editor_undo(h); updateInfo() }
    func redo() { guard let h = handle else { return }; matcha_editor_redo(h); updateInfo() }

    // MARK: - Viewport

    func setViewport(width: UInt32, height: UInt32, cellWidth: Float, cellHeight: Float) {
        guard let h = handle else { return }
        matcha_editor_set_viewport(h, width, height, cellWidth, cellHeight)
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

    func getScrollY() -> Float {
        guard let h = handle else { return 0 }
        return matcha_editor_get_scroll_y(h)
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

    func getLineNumbers() -> UnsafeBufferPointer<matcha_render_rect_s> {
        guard let h = handle else { return UnsafeBufferPointer(start: nil, count: 0) }
        var count: UInt32 = 0
        guard let ptr = matcha_editor_get_line_number_cells(h, &count) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return UnsafeBufferPointer(start: ptr, count: Int(count))
    }

    // MARK: - Info

    func updateInfo() {
        guard let h = handle else { return }
        let cInfo = matcha_editor_get_info(h)
        var fname: String? = nil
        if let f = cInfo.filename {
            fname = String(cString: f)
            matcha_editor_free_string(UnsafeMutablePointer(mutating: f))
        }
        DispatchQueue.main.async { [weak self] in
            self?.info = EditorInfo(
                cursorLine: cInfo.cursor_line,
                cursorCol: cInfo.cursor_col,
                totalLines: cInfo.total_lines,
                modified: cInfo.modified,
                filename: fname
            )
        }
    }
}
