const std = @import("std");
const Editor = @import("editor/Editor.zig").Editor;
const Config = @import("config/Config.zig").Config;
const Parser = @import("config/Parser.zig");
const Cell = @import("render/Cell.zig");

const c_allocator = std.heap.c_allocator;

// ── Lifecycle ──────────────────────────────────────────────────

export fn matcha_init() void {
    // Global initialization (reserved for future use)
}

// ── Config ─────────────────────────────────────────────────────

export fn matcha_config_new() ?*Config {
    const cfg = c_allocator.create(Config) catch return null;
    cfg.* = Config.defaults();
    cfg.allocator = c_allocator;
    return cfg;
}

export fn matcha_config_free(cfg: ?*Config) void {
    if (cfg) |c| {
        c.deinit();
        c_allocator.destroy(c);
    }
}

export fn matcha_config_load_file(cfg: ?*Config, path: ?[*:0]const u8) bool {
    const c = cfg orelse return false;
    const p = path orelse return false;
    const slice = std.mem.span(p);
    Parser.parseFile(c_allocator, c, slice) catch return false;
    return true;
}

export fn matcha_config_get_string(cfg: ?*Config, key: ?[*:0]const u8) ?[*:0]const u8 {
    const c = cfg orelse return null;
    const k = key orelse return null;
    const slice = std.mem.span(k);

    if (std.mem.eql(u8, slice, "font-family")) {
        // Return a null-terminated copy
        const dup = c_allocator.dupeZ(u8, c.font_family) catch return null;
        return dup.ptr;
    }
    return null;
}

export fn matcha_config_get_int(cfg: ?*Config, key: ?[*:0]const u8) i64 {
    const c = cfg orelse return 0;
    const k = key orelse return 0;
    const slice = std.mem.span(k);

    if (std.mem.eql(u8, slice, "tab-size")) return @intCast(c.tab_size);
    return 0;
}

export fn matcha_config_get_bool(cfg: ?*Config, key: ?[*:0]const u8) bool {
    const c = cfg orelse return false;
    const k = key orelse return false;
    const slice = std.mem.span(k);

    if (std.mem.eql(u8, slice, "insert-spaces")) return c.insert_spaces;
    if (std.mem.eql(u8, slice, "line-numbers")) return c.line_numbers;
    return false;
}

export fn matcha_config_get_float(cfg: ?*Config, key: ?[*:0]const u8) f64 {
    const c = cfg orelse return 0;
    const k = key orelse return 0;
    const slice = std.mem.span(k);

    if (std.mem.eql(u8, slice, "font-size")) return c.font_size;
    return 0;
}

// ── Editor ─────────────────────────────────────────────────────

export fn matcha_editor_new(cfg: ?*Config) ?*Editor {
    const c = cfg orelse return null;
    const ed = c_allocator.create(Editor) catch return null;
    ed.* = Editor.init(c_allocator, c);
    return ed;
}

export fn matcha_editor_free(ed: ?*Editor) void {
    if (ed) |e| {
        e.deinit();
        c_allocator.destroy(e);
    }
}

// ── File I/O ───────────────────────────────────────────────────

export fn matcha_editor_new_file(ed: ?*Editor) void {
    const e = ed orelse return;
    e.newFile();
}

export fn matcha_editor_open_file(ed: ?*Editor, path: ?[*:0]const u8) bool {
    const e = ed orelse return false;
    const p = path orelse return false;
    e.openFile(std.mem.span(p)) catch |err| {
        e.setLastError(err);
        return false;
    };
    return true;
}

export fn matcha_editor_save(ed: ?*Editor) bool {
    const e = ed orelse return false;
    e.save() catch |err| {
        e.setLastError(err);
        return false;
    };
    return true;
}

export fn matcha_editor_save_as(ed: ?*Editor, path: ?[*:0]const u8) bool {
    const e = ed orelse return false;
    const p = path orelse return false;
    e.saveAs(std.mem.span(p)) catch |err| {
        e.setLastError(err);
        return false;
    };
    return true;
}

// ── Error feedback ─────────────────────────────────────────────

export fn matcha_editor_get_last_error(ed: ?*Editor) ?[*:0]const u8 {
    const e = ed orelse return null;
    if (!e.has_error) return null;
    return @ptrCast(&e.error_msg);
}

export fn matcha_editor_clear_error(ed: ?*Editor) void {
    if (ed) |e| e.clearLastError();
}

// ── Editing ────────────────────────────────────────────────────

export fn matcha_editor_insert(ed: ?*Editor, text: ?[*]const u8, len: u32) void {
    const e = ed orelse return;
    const t = text orelse return;
    e.insertText(t[0..len]) catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_delete_backward(ed: ?*Editor) void {
    const e = ed orelse return;
    e.deleteBackward() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_delete_forward(ed: ?*Editor) void {
    const e = ed orelse return;
    e.deleteForward() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_delete_word_backward(ed: ?*Editor) void {
    const e = ed orelse return;
    e.deleteWordBackward() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_delete_word_forward(ed: ?*Editor) void {
    const e = ed orelse return;
    e.deleteWordForward() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_newline(ed: ?*Editor) void {
    const e = ed orelse return;
    e.newline() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_toggle_comment(ed: ?*Editor) void {
    const e = ed orelse return;
    e.toggleComment() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_duplicate_line(ed: ?*Editor) void {
    const e = ed orelse return;
    e.duplicateLine() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_move_line_up(ed: ?*Editor) void {
    const e = ed orelse return;
    e.moveLineUp() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_move_line_down(ed: ?*Editor) void {
    const e = ed orelse return;
    e.moveLineDown() catch |err| {
        e.setLastError(err);
    };
}

// ── Tab / Indent ───────────────────────────────────────────────

export fn matcha_editor_insert_tab(ed: ?*Editor) void {
    const e = ed orelse return;
    e.insertTab() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_dedent(ed: ?*Editor) void {
    const e = ed orelse return;
    e.dedent() catch |err| {
        e.setLastError(err);
    };
}

// ── Movement ───────────────────────────────────────────────────

export fn matcha_editor_move_left(ed: ?*Editor) void {
    if (ed) |e| e.moveLeft();
}

export fn matcha_editor_move_right(ed: ?*Editor) void {
    if (ed) |e| e.moveRight();
}

export fn matcha_editor_move_up(ed: ?*Editor) void {
    if (ed) |e| e.moveUp();
}

export fn matcha_editor_move_down(ed: ?*Editor) void {
    if (ed) |e| e.moveDown();
}

export fn matcha_editor_move_line_start(ed: ?*Editor) void {
    if (ed) |e| e.moveLineStart();
}

export fn matcha_editor_move_line_end(ed: ?*Editor) void {
    if (ed) |e| e.moveLineEnd();
}

export fn matcha_editor_move_start(ed: ?*Editor) void {
    if (ed) |e| e.moveStart();
}

export fn matcha_editor_move_end(ed: ?*Editor) void {
    if (ed) |e| e.moveEnd();
}

export fn matcha_editor_move_page_up(ed: ?*Editor) void {
    if (ed) |e| e.movePageUp();
}

export fn matcha_editor_move_page_down(ed: ?*Editor) void {
    if (ed) |e| e.movePageDown();
}

export fn matcha_editor_move_word_left(ed: ?*Editor) void {
    if (ed) |e| e.moveWordLeft();
}

export fn matcha_editor_move_word_right(ed: ?*Editor) void {
    if (ed) |e| e.moveWordRight();
}

export fn matcha_editor_go_to_line(ed: ?*Editor, line: u32) void {
    if (ed) |e| e.goToLine(if (line > 0) line - 1 else 0); // convert 1-based to 0-based
}

// ── Selection ──────────────────────────────────────────────────

export fn matcha_editor_select_left(ed: ?*Editor) void {
    if (ed) |e| e.selectLeft();
}

export fn matcha_editor_select_right(ed: ?*Editor) void {
    if (ed) |e| e.selectRight();
}

export fn matcha_editor_select_up(ed: ?*Editor) void {
    if (ed) |e| e.selectUp();
}

export fn matcha_editor_select_down(ed: ?*Editor) void {
    if (ed) |e| e.selectDown();
}

export fn matcha_editor_select_line_start(ed: ?*Editor) void {
    if (ed) |e| e.selectLineStart();
}

export fn matcha_editor_select_line_end(ed: ?*Editor) void {
    if (ed) |e| e.selectLineEnd();
}

export fn matcha_editor_select_all(ed: ?*Editor) void {
    if (ed) |e| e.selectAll();
}

export fn matcha_editor_select_start(ed: ?*Editor) void {
    if (ed) |e| e.selectStart();
}

export fn matcha_editor_select_end(ed: ?*Editor) void {
    if (ed) |e| e.selectEnd();
}

export fn matcha_editor_select_word_left(ed: ?*Editor) void {
    if (ed) |e| e.selectWordLeft();
}

export fn matcha_editor_select_word_right(ed: ?*Editor) void {
    if (ed) |e| e.selectWordRight();
}

// ── Clipboard ──────────────────────────────────────────────────

export fn matcha_editor_get_selection_text(ed: ?*Editor) ?[*:0]u8 {
    const e = ed orelse return null;
    const text = e.getSelectionText() orelse return null;
    defer e.allocator.free(text);
    // Copy to C-owned null-terminated string
    const result = c_allocator.allocSentinel(u8, text.len, 0) catch return null;
    @memcpy(result[0..text.len], text);
    return result.ptr;
}

export fn matcha_editor_get_content(ed: ?*Editor, len: ?*u32) ?[*:0]u8 {
    const e = ed orelse return null;
    const content = e.buffer.getContent(e.allocator) catch return null;
    defer e.allocator.free(content);

    const result = c_allocator.allocSentinel(u8, content.len, 0) catch return null;
    @memcpy(result[0..content.len], content);
    if (len) |out_len| out_len.* = @intCast(content.len);
    return result.ptr;
}

export fn matcha_editor_get_selection_offsets(ed: ?*Editor, start: ?*u32, end: ?*u32) bool {
    const e = ed orelse return false;
    const range = e.selectionPosRange() orelse return false;
    if (start) |out_start| out_start.* = range.start;
    if (end) |out_end| out_end.* = range.end;
    return true;
}

export fn matcha_editor_get_cursor_offset(ed: ?*Editor) u32 {
    const e = ed orelse return 0;
    return e.cursorPos();
}

export fn matcha_editor_paste(ed: ?*Editor, text: ?[*]const u8, len: u32) void {
    const e = ed orelse return;
    const t = text orelse return;
    e.paste(t[0..len]) catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_replace_range(ed: ?*Editor, start: u32, end: u32, text: ?[*]const u8, len: u32) void {
    const e = ed orelse return;
    const t = text orelse return;
    e.replaceRangeLiteral(start, end, t[0..len]) catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_set_cursor_offset(ed: ?*Editor, pos: u32) void {
    if (ed) |e| e.setCursorPos(pos);
}

export fn matcha_editor_set_selection_offsets(ed: ?*Editor, start: u32, end: u32) void {
    if (ed) |e| e.setSelectionPosRange(start, end);
}

export fn matcha_editor_free_string(str: ?[*:0]u8) void {
    if (str) |s| {
        const slice = std.mem.span(s);
        c_allocator.free(slice[0 .. slice.len + 1]); // +1 for sentinel
    }
}

export fn matcha_free_string(str: ?[*:0]u8) void {
    if (str) |s| {
        const slice = std.mem.span(s);
        c_allocator.free(slice[0 .. slice.len + 1]);
    }
}

// ── Undo/Redo ──────────────────────────────────────────────────

export fn matcha_editor_undo(ed: ?*Editor) void {
    if (ed) |e| e.undo() catch |err| {
        e.setLastError(err);
    };
}

export fn matcha_editor_redo(ed: ?*Editor) void {
    if (ed) |e| e.redo() catch |err| {
        e.setLastError(err);
    };
}

// ── Input ──────────────────────────────────────────────────────

const InputKey = extern struct {
    keycode: u16,
    modifiers: u32,
    text: ?[*]const u8,
    text_len: u32,
};

const mod_shift: u32 = 1 << 0;
const mod_alt: u32 = 1 << 2;
const mod_super: u32 = 1 << 3;

fn hasModifier(modifiers: u32, flag: u32) bool {
    return (modifiers & flag) != 0;
}

export fn matcha_editor_key_event(ed: ?*Editor, key: InputKey) bool {
    const e = ed orelse return false;
    const has_shift = hasModifier(key.modifiers, mod_shift);
    const has_alt = hasModifier(key.modifiers, mod_alt);
    const has_super = hasModifier(key.modifiers, mod_super);
    const text = if (key.text) |ptr| ptr[0..key.text_len] else "";

    if (has_super) {
        switch (key.keycode) {
            0 => {
                e.selectAll();
                return true;
            },
            2 => {
                e.duplicateLine() catch |err| e.setLastError(err);
                return true;
            },
            6 => {
                if (has_shift) {
                    e.redo() catch |err| e.setLastError(err);
                } else {
                    e.undo() catch |err| e.setLastError(err);
                }
                return true;
            },
            44 => {
                e.toggleComment() catch |err| e.setLastError(err);
                return true;
            },
            else => {},
        }
    }

    switch (key.keycode) {
        36 => {
            e.newline() catch |err| e.setLastError(err);
            return true;
        },
        48 => {
            if (has_shift) {
                e.dedent() catch |err| e.setLastError(err);
            } else {
                e.insertTab() catch |err| e.setLastError(err);
            }
            return true;
        },
        51 => {
            if (has_alt) {
                e.deleteWordBackward() catch |err| e.setLastError(err);
            } else {
                e.deleteBackward() catch |err| e.setLastError(err);
            }
            return true;
        },
        115 => {
            e.moveStart();
            return true;
        },
        116 => {
            e.movePageUp();
            return true;
        },
        117 => {
            if (has_alt) {
                e.deleteWordForward() catch |err| e.setLastError(err);
            } else {
                e.deleteForward() catch |err| e.setLastError(err);
            }
            return true;
        },
        119 => {
            e.moveEnd();
            return true;
        },
        121 => {
            e.movePageDown();
            return true;
        },
        123 => {
            if (has_super) {
                if (has_shift) e.selectLineStart() else e.moveLineStart();
            } else if (has_alt) {
                if (has_shift) e.selectWordLeft() else e.moveWordLeft();
            } else {
                if (has_shift) e.selectLeft() else e.moveLeft();
            }
            return true;
        },
        124 => {
            if (has_super) {
                if (has_shift) e.selectLineEnd() else e.moveLineEnd();
            } else if (has_alt) {
                if (has_shift) e.selectWordRight() else e.moveWordRight();
            } else {
                if (has_shift) e.selectRight() else e.moveRight();
            }
            return true;
        },
        125 => {
            if (has_super and has_alt) {
                e.moveLineDown() catch |err| e.setLastError(err);
            } else if (has_super) {
                if (has_shift) e.selectEnd() else e.moveEnd();
            } else {
                if (has_shift) e.selectDown() else e.moveDown();
            }
            return true;
        },
        126 => {
            if (has_super and has_alt) {
                e.moveLineUp() catch |err| e.setLastError(err);
            } else if (has_super) {
                if (has_shift) e.selectStart() else e.moveStart();
            } else {
                if (has_shift) e.selectUp() else e.moveUp();
            }
            return true;
        },
        else => {},
    }

    if (!has_super and text.len > 0) {
        e.insertText(text) catch |err| e.setLastError(err);
        return true;
    }

    return false;
}

// ── Find & Replace ─────────────────────────────────────────

export fn matcha_editor_find_next(ed: ?*Editor, query: ?[*]const u8, len: u32) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    return e.findNext(q[0..len]);
}

export fn matcha_editor_find_prev(ed: ?*Editor, query: ?[*]const u8, len: u32) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    return e.findPrev(q[0..len]);
}

export fn matcha_editor_find_next_with_options(ed: ?*Editor, query: ?[*]const u8, len: u32, case_sensitive: bool, whole_word: bool) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    return e.findNextWithOptions(q[0..len], .{ .case_sensitive = case_sensitive, .whole_word = whole_word });
}

export fn matcha_editor_find_prev_with_options(ed: ?*Editor, query: ?[*]const u8, len: u32, case_sensitive: bool, whole_word: bool) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    return e.findPrevWithOptions(q[0..len], .{ .case_sensitive = case_sensitive, .whole_word = whole_word });
}

export fn matcha_editor_replace_next(ed: ?*Editor, query: ?[*]const u8, q_len: u32, replacement: ?[*]const u8, r_len: u32) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    const r = replacement orelse return false;
    return e.replaceNext(q[0..q_len], r[0..r_len]) catch |err| {
        e.setLastError(err);
        return false;
    };
}

export fn matcha_editor_replace_next_with_options(ed: ?*Editor, query: ?[*]const u8, q_len: u32, replacement: ?[*]const u8, r_len: u32, case_sensitive: bool, whole_word: bool) bool {
    const e = ed orelse return false;
    const q = query orelse return false;
    const r = replacement orelse return false;
    return e.replaceNextWithOptions(q[0..q_len], r[0..r_len], .{
        .case_sensitive = case_sensitive,
        .whole_word = whole_word,
    }) catch |err| {
        e.setLastError(err);
        return false;
    };
}

export fn matcha_editor_replace_all(ed: ?*Editor, query: ?[*]const u8, q_len: u32, replacement: ?[*]const u8, r_len: u32) u32 {
    const e = ed orelse return 0;
    const q = query orelse return 0;
    const r = replacement orelse return 0;
    return e.replaceAll(q[0..q_len], r[0..r_len]) catch |err| {
        e.setLastError(err);
        return 0;
    };
}

export fn matcha_editor_replace_all_with_options(ed: ?*Editor, query: ?[*]const u8, q_len: u32, replacement: ?[*]const u8, r_len: u32, case_sensitive: bool, whole_word: bool) u32 {
    const e = ed orelse return 0;
    const q = query orelse return 0;
    const r = replacement orelse return 0;
    return e.replaceAllWithOptions(q[0..q_len], r[0..r_len], .{
        .case_sensitive = case_sensitive,
        .whole_word = whole_word,
    }) catch |err| {
        e.setLastError(err);
        return 0;
    };
}

// ── Bracket highlights ────────────────────────────────────────

export fn matcha_editor_get_bracket_highlights(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderRect {
    const e = ed orelse return null;
    const items = e.render_state.bracket_highlights.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

// ── Viewport ───────────────────────────────────────────────────

export fn matcha_editor_set_viewport(ed: ?*Editor, width: u32, height: u32, cell_w: f32, cell_h: f32) void {
    if (ed) |e| e.setViewport(width, height, cell_w, cell_h);
}

export fn matcha_editor_set_wide_cell_width(ed: ?*Editor, wide_cell_w: f32) void {
    if (ed) |e| e.setWideCellWidth(wide_cell_w);
}

export fn matcha_editor_set_hangul_cell_width(ed: ?*Editor, hangul_cell_w: f32) void {
    if (ed) |e| e.setHangulCellWidth(hangul_cell_w);
}

export fn matcha_editor_scroll(ed: ?*Editor, dx: f32, dy: f32) void {
    if (ed) |e| e.scroll(dx, dy);
}

export fn matcha_editor_click(ed: ?*Editor, x: f32, y: f32, extend: bool) void {
    if (ed) |e| e.click(x, y, extend);
}

export fn matcha_editor_double_click(ed: ?*Editor, x: f32, y: f32) void {
    if (ed) |e| e.doubleClick(x, y);
}

export fn matcha_editor_triple_click(ed: ?*Editor, x: f32, y: f32) void {
    if (ed) |e| e.tripleClick(x, y);
}

export fn matcha_editor_hit_test_offset(ed: ?*Editor, x: f32, y: f32) u32 {
    const e = ed orelse return 0;
    return e.screenToPos(x, y);
}

export fn matcha_editor_get_rect_for_offset(ed: ?*Editor, pos: u32, x: ?*f32, y: ?*f32, w: ?*f32, h: ?*f32) bool {
    const e = ed orelse return false;
    const rect = e.rectForPos(pos);
    if (x) |out_x| out_x.* = rect.x;
    if (y) |out_y| out_y.* = rect.y;
    if (w) |out_w| out_w.* = rect.w;
    if (h) |out_h| out_h.* = rect.h;
    return true;
}

export fn matcha_editor_get_scroll_y(ed: ?*Editor) f32 {
    const e = ed orelse return 0;
    return e.scroll_y;
}

// ── Render ─────────────────────────────────────────────────────

export fn matcha_editor_prepare_render(ed: ?*Editor) void {
    if (ed) |e| e.prepareRender();
}

export fn matcha_editor_get_cells(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderCell {
    const e = ed orelse return null;
    const items = e.render_state.cells.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

export fn matcha_editor_get_cursors(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderCursor {
    const e = ed orelse return null;
    const items = e.render_state.cursors.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

export fn matcha_editor_get_selections(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderRect {
    const e = ed orelse return null;
    const items = e.render_state.selections.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

export fn matcha_editor_get_line_number_cells(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderRect {
    const e = ed orelse return null;
    const items = e.render_state.line_numbers.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

export fn matcha_editor_get_line_number_labels(ed: ?*Editor, count: ?*u32) ?[*]const Cell.RenderLineNumber {
    const e = ed orelse return null;
    const items = e.render_state.line_number_labels.items;
    if (count) |c| c.* = @intCast(items.len);
    if (items.len == 0) return null;
    return items.ptr;
}

export fn matcha_editor_get_atlas_data(ed: ?*Editor, width: ?*u32, height: ?*u32) ?[*]const u8 {
    _ = ed;
    if (width) |w| w.* = 0;
    if (height) |h| h.* = 0;
    return null; // Atlas data not yet wired — Metal side uses CoreText directly for now
}

export fn matcha_editor_atlas_needs_update(ed: ?*Editor) bool {
    _ = ed;
    return false;
}

export fn matcha_editor_atlas_clear_dirty(ed: ?*Editor) void {
    _ = ed;
}

// ── Info ───────────────────────────────────────────────────────

const EditorInfo = extern struct {
    cursor_line: u32,
    cursor_col: u32,
    total_lines: u32,
    modified: bool,
    filename: ?[*:0]const u8,
};

export fn matcha_editor_get_info(ed: ?*Editor) EditorInfo {
    const e = ed orelse return .{
        .cursor_line = 1,
        .cursor_col = 1,
        .total_lines = 1,
        .modified = false,
        .filename = null,
    };
    return .{
        .cursor_line = e.cursor.line + 1, // 1-based for display
        .cursor_col = e.cursor.col + 1,
        .total_lines = e.buffer.lineCount(),
        .modified = e.modified,
        .filename = if (e.filename_z) |z| z.ptr else null,
    };
}

const testing = std.testing;

fn expectEditorContent(ed: *Editor, expected: []const u8) !void {
    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

test "main_c: key event inserts text" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try testing.expect(matcha_editor_key_event(&ed, .{
        .keycode = 0,
        .modifiers = 0,
        .text = "x".ptr,
        .text_len = 1,
    }));

    try expectEditorContent(&ed, "x");
}

test "main_c: key event handles undo shortcut" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("x");

    try testing.expect(matcha_editor_key_event(&ed, .{
        .keycode = 6,
        .modifiers = mod_super,
        .text = null,
        .text_len = 0,
    }));

    try expectEditorContent(&ed, "");
}

test "main_c: content and selection offsets expose editor state" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("hello");
    matcha_editor_set_selection_offsets(&ed, 1, 4);

    var len: u32 = 0;
    const content_ptr = matcha_editor_get_content(&ed, &len).?;
    defer matcha_editor_free_string(content_ptr);
    try testing.expectEqual(@as(u32, 5), len);
    try testing.expectEqualStrings("hello", std.mem.span(content_ptr));

    try testing.expectEqual(@as(u32, 4), matcha_editor_get_cursor_offset(&ed));

    var start: u32 = 0;
    var end: u32 = 0;
    try testing.expect(matcha_editor_get_selection_offsets(&ed, &start, &end));
    try testing.expectEqual(@as(u32, 1), start);
    try testing.expectEqual(@as(u32, 4), end);
}

test "main_c: replace range inserts literal text" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("abc");
    matcha_editor_replace_range(&ed, 1, 2, "(".ptr, 1);

    try expectEditorContent(&ed, "a(c");
    try testing.expectEqual(@as(u32, 2), ed.cursor.col);
}

test "main_c: rect and hit test stay aligned for fullwidth characters" {
    var config = Config.defaults();
    config.line_numbers = false;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    matcha_editor_set_viewport(&ed, 80, 20, 1, 1);
    matcha_editor_set_wide_cell_width(&ed, 1.5);
    try ed.insertText("a好b");

    var x: f32 = 0;
    var y: f32 = 0;
    var w: f32 = 0;
    var h: f32 = 0;
    try testing.expect(matcha_editor_get_rect_for_offset(&ed, 4, &x, &y, &w, &h));
    try testing.expectEqual(@as(f32, 2.5), x);
    try testing.expectEqual(@as(f32, 1), w);
    try testing.expectEqual(@as(f32, 1), h);

    try testing.expectEqual(@as(u32, 1), matcha_editor_hit_test_offset(&ed, 1.2, 0.5));
    try testing.expectEqual(@as(u32, 4), matcha_editor_hit_test_offset(&ed, 2.2, 0.5));
}

test "main_c: wrapped hit testing follows pixel-based row breaks" {
    var config = Config.defaults();
    config.line_numbers = false;
    config.wrap_lines = true;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    matcha_editor_set_viewport(&ed, 4, 10, 1, 1);
    matcha_editor_set_wide_cell_width(&ed, 1.5);
    try ed.insertText("a好bc");

    try testing.expectEqual(@as(u32, 5), matcha_editor_hit_test_offset(&ed, 3.8, 0.5));
}
