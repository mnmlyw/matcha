const std = @import("std");
const Allocator = std.mem.Allocator;
const PieceTable = @import("../buffer/PieceTable.zig").PieceTable;
const Cursor = @import("Cursor.zig").Cursor;
const Selection = @import("Selection.zig").Selection;
const UndoStack = @import("UndoStack.zig").UndoStack;
const OpKind = @import("UndoStack.zig").OpKind;
const Config = @import("../config/Config.zig").Config;
const Cell = @import("../render/Cell.zig");
const RenderState = @import("../render/RenderState.zig").RenderState;
const Language = @import("../highlight/Language.zig").Language;

pub const Editor = struct {
    allocator: Allocator,
    buffer: PieceTable,
    cursor: Cursor,
    selection: Selection,
    undo_stack: UndoStack,
    config: *const Config,
    render_state: RenderState,

    // Viewport
    viewport_width: u32 = 800,
    viewport_height: u32 = 600,
    cell_width: f32 = 8.0,
    cell_height: f32 = 16.0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    // File state
    filename: ?[]const u8 = null,
    filename_owned: bool = false,
    modified: bool = false,

    // Syntax highlighting
    language: Language = .none,

    pub fn init(allocator: Allocator, config: *const Config) Editor {
        return .{
            .allocator = allocator,
            .buffer = PieceTable.init(allocator),
            .cursor = .{},
            .selection = .{},
            .undo_stack = UndoStack.init(allocator),
            .config = config,
            .render_state = RenderState.init(allocator),
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.undo_stack.deinit();
        self.render_state.deinit();
        if (self.filename_owned) {
            if (self.filename) |f| self.allocator.free(f);
        }
    }

    // ── File I/O ───────────────────────────────────────────────

    pub fn openFile(self: *Editor, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 100 * 1024 * 1024); // 100MB max
        defer self.allocator.free(content);

        self.buffer.deinit();
        self.buffer = try PieceTable.initWithContent(self.allocator, content);
        self.cursor = .{};
        self.selection = .{};
        self.modified = false;

        if (self.filename_owned) {
            if (self.filename) |f| self.allocator.free(f);
        }
        self.filename = try self.allocator.dupe(u8, path);
        self.filename_owned = true;
        self.language = Language.detectFromFilename(path);
    }

    pub fn save(self: *Editor) !void {
        const fname = self.filename orelse return error.NoFilename;
        try self.saveAs(fname);
    }

    pub fn saveAs(self: *Editor, path: []const u8) !void {
        const content = try self.buffer.getContent(self.allocator);
        defer self.allocator.free(content);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);

        if (!std.mem.eql(u8, path, self.filename orelse "")) {
            if (self.filename_owned) {
                if (self.filename) |f| self.allocator.free(f);
            }
            self.filename = try self.allocator.dupe(u8, path);
            self.filename_owned = true;
        }
        self.modified = false;
    }

    // ── Editing ────────────────────────────────────────────────

    pub fn insertText(self: *Editor, text: []const u8) !void {
        // If there's a selection, delete it first
        if (self.selection.active) {
            try self.deleteSelection();
        }

        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.insert, pos, text);

        try self.buffer.insert(pos, text);
        self.modified = true;

        // Advance cursor
        for (text) |ch| {
            if (ch == '\n') {
                self.cursor.line += 1;
                self.cursor.col = 0;
            } else {
                self.cursor.col += 1;
            }
        }
        self.cursor.target_col = self.cursor.col;

        try self.undo_stack.commit();
        self.ensureCursorVisible();
    }

    pub fn deleteBackward(self: *Editor) !void {
        if (self.selection.active) {
            try self.deleteSelection();
            return;
        }

        if (self.cursor.line == 0 and self.cursor.col == 0) return;

        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        if (pos == 0) return;

        // Get the byte we're deleting for undo
        const del_byte = self.buffer.byteAt(pos - 1) orelse return;

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, pos - 1, &.{del_byte});

        try self.buffer.delete(pos - 1, 1);
        self.modified = true;

        // Move cursor back
        if (del_byte == '\n') {
            self.cursor.line -= 1;
            self.cursor.col = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
        } else {
            self.cursor.col -= 1;
        }
        self.cursor.target_col = self.cursor.col;

        try self.undo_stack.commit();
        self.ensureCursorVisible();
    }

    pub fn deleteForward(self: *Editor) !void {
        if (self.selection.active) {
            try self.deleteSelection();
            return;
        }

        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        if (pos >= self.buffer.totalLength()) return;

        const del_byte = self.buffer.byteAt(pos) orelse return;

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, pos, &.{del_byte});

        try self.buffer.delete(pos, 1);
        self.modified = true;

        try self.undo_stack.commit();
    }

    pub fn newline(self: *Editor) !void {
        // Auto-indent: copy leading whitespace from current line
        const line_start = self.buffer.lineStart(self.cursor.line);
        const line_end = self.buffer.lineEnd(self.cursor.line);
        var indent_len: u32 = 0;
        while (indent_len < (line_end - line_start)) {
            const b = self.buffer.byteAt(line_start + indent_len) orelse break;
            if (b != ' ' and b != '\t') break;
            indent_len += 1;
        }
        // Don't indent more than cursor column
        indent_len = @min(indent_len, self.cursor.col);

        if (indent_len == 0) {
            try self.insertText("\n");
        } else {
            var buf: [257]u8 = undefined;
            buf[0] = '\n';
            const copy_len = @min(indent_len, 256);
            var i: u32 = 0;
            while (i < copy_len) : (i += 1) {
                buf[i + 1] = self.buffer.byteAt(line_start + i) orelse ' ';
            }
            try self.insertText(buf[0 .. i + 1]);
        }
    }

    fn deleteSelection(self: *Editor) !void {
        if (!self.selection.active) return;

        const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
        const start_pos = self.buffer.lineColToPos(range.start_line, range.start_col);
        const end_pos = self.buffer.lineColToPos(range.end_line, range.end_col);

        if (end_pos <= start_pos) {
            self.selection.clear();
            return;
        }

        const deleted = try self.buffer.getRange(self.allocator, start_pos, end_pos);
        defer self.allocator.free(deleted);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, start_pos, deleted);

        try self.buffer.delete(start_pos, end_pos - start_pos);
        self.modified = true;

        self.cursor.moveTo(range.start_line, range.start_col);
        self.selection.clear();

        try self.undo_stack.commit();
        self.ensureCursorVisible();
    }

    // ── Movement ───────────────────────────────────────────────

    pub fn moveLeft(self: *Editor) void {
        self.selection.clear();
        self.moveCursorLeft();
    }

    pub fn moveRight(self: *Editor) void {
        self.selection.clear();
        self.moveCursorRight();
    }

    pub fn moveUp(self: *Editor) void {
        self.selection.clear();
        self.moveCursorUp();
    }

    pub fn moveDown(self: *Editor) void {
        self.selection.clear();
        self.moveCursorDown();
    }

    pub fn moveLineStart(self: *Editor) void {
        self.selection.clear();
        self.cursor.moveTo(self.cursor.line, 0);
        self.ensureCursorVisible();
    }

    pub fn moveLineEnd(self: *Editor) void {
        self.selection.clear();
        const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
        self.cursor.moveTo(self.cursor.line, line_len);
        self.ensureCursorVisible();
    }

    pub fn moveStart(self: *Editor) void {
        self.selection.clear();
        self.cursor.moveTo(0, 0);
        self.ensureCursorVisible();
    }

    pub fn moveEnd(self: *Editor) void {
        self.selection.clear();
        const last_line = self.buffer.lineCount() -| 1;
        const line_len = self.buffer.lineEnd(last_line) - self.buffer.lineStart(last_line);
        self.cursor.moveTo(last_line, line_len);
        self.ensureCursorVisible();
    }

    pub fn movePageUp(self: *Editor) void {
        self.selection.clear();
        const page_lines = self.visibleLines();
        if (self.cursor.line >= page_lines) {
            self.cursor.moveToKeepTarget(self.cursor.line - page_lines, self.cursor.col);
        } else {
            self.cursor.moveToKeepTarget(0, self.cursor.col);
        }
        self.clampCursorCol();
        self.ensureCursorVisible();
    }

    pub fn movePageDown(self: *Editor) void {
        self.selection.clear();
        const page_lines = self.visibleLines();
        const max_line = self.buffer.lineCount() -| 1;
        const new_line = @min(self.cursor.line + page_lines, max_line);
        self.cursor.moveToKeepTarget(new_line, self.cursor.col);
        self.clampCursorCol();
        self.ensureCursorVisible();
    }

    pub fn moveWordLeft(self: *Editor) void {
        self.selection.clear();
        self.moveCursorWordLeft();
    }

    pub fn moveWordRight(self: *Editor) void {
        self.selection.clear();
        self.moveCursorWordRight();
    }

    // ── Selection movement ─────────────────────────────────────

    fn startSelectionIfNeeded(self: *Editor) void {
        if (!self.selection.active) {
            self.selection.setAnchor(self.cursor.line, self.cursor.col);
        }
    }

    pub fn selectLeft(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorLeft();
    }

    pub fn selectRight(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorRight();
    }

    pub fn selectUp(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorUp();
    }

    pub fn selectDown(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorDown();
    }

    pub fn selectLineStart(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.cursor.moveTo(self.cursor.line, 0);
        self.ensureCursorVisible();
    }

    pub fn selectLineEnd(self: *Editor) void {
        self.startSelectionIfNeeded();
        const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
        self.cursor.moveTo(self.cursor.line, line_len);
        self.ensureCursorVisible();
    }

    pub fn selectAll(self: *Editor) void {
        self.selection.setAnchor(0, 0);
        const last_line = self.buffer.lineCount() -| 1;
        const line_len = self.buffer.lineEnd(last_line) - self.buffer.lineStart(last_line);
        self.cursor.moveTo(last_line, line_len);
    }

    pub fn selectWordLeft(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorWordLeft();
    }

    pub fn selectWordRight(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.moveCursorWordRight();
    }

    // ── Clipboard ──────────────────────────────────────────────

    pub fn getSelectionText(self: *Editor) ?[]u8 {
        if (!self.selection.active) return null;

        const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
        const start_pos = self.buffer.lineColToPos(range.start_line, range.start_col);
        const end_pos = self.buffer.lineColToPos(range.end_line, range.end_col);

        if (end_pos <= start_pos) return null;

        return self.buffer.getRange(self.allocator, start_pos, end_pos) catch null;
    }

    pub fn paste(self: *Editor, text: []const u8) !void {
        try self.insertText(text);
    }

    // ── Undo/Redo ──────────────────────────────────────────────

    pub fn undo(self: *Editor) !void {
        const group = self.undo_stack.popUndo() orelse return;

        // Apply inverse operations in reverse order
        var i: usize = group.ops.len;
        while (i > 0) {
            i -= 1;
            const op = group.ops[i];
            switch (op.kind) {
                .insert => try self.buffer.delete(op.pos, @intCast(op.text.len)),
                .delete => try self.buffer.insert(op.pos, op.text),
            }
        }

        self.cursor.moveTo(group.cursor_line, group.cursor_col);
        self.selection.clear();
        self.modified = true;

        try self.undo_stack.pushRedo(group);
        self.ensureCursorVisible();
    }

    pub fn redo(self: *Editor) !void {
        const group = self.undo_stack.popRedo() orelse return;

        // Re-apply operations in forward order
        for (group.ops) |op| {
            switch (op.kind) {
                .insert => try self.buffer.insert(op.pos, op.text),
                .delete => try self.buffer.delete(op.pos, @intCast(op.text.len)),
            }
        }

        // Move cursor to end of last operation
        if (group.ops.len > 0) {
            const last = group.ops[group.ops.len - 1];
            const end_pos = switch (last.kind) {
                .insert => last.pos + @as(u32, @intCast(last.text.len)),
                .delete => last.pos,
            };
            const lc = self.buffer.posToLineCol(end_pos);
            self.cursor.moveTo(lc.line, lc.col);
        }

        self.selection.clear();
        self.modified = true;

        try self.undo_stack.pushUndo(group);
        self.ensureCursorVisible();
    }

    // ── Viewport ───────────────────────────────────────────────

    pub fn setViewport(self: *Editor, width: u32, height: u32, cell_w: f32, cell_h: f32) void {
        self.viewport_width = width;
        self.viewport_height = height;
        self.cell_width = cell_w;
        self.cell_height = cell_h;
    }

    pub fn scroll(self: *Editor, dx: f32, dy: f32) void {
        self.scroll_x = @max(0, self.scroll_x + dx);
        self.scroll_y = @max(0, self.scroll_y + dy);
        self.clampScroll();
    }

    fn clampScroll(self: *Editor) void {
        const gutter_w = self.gutterWidth();
        const view_w = @as(f32, @floatFromInt(self.viewport_width)) - gutter_w;
        const view_h = @as(f32, @floatFromInt(self.viewport_height));

        // Vertical: stop when last line is visible
        const total_h = @as(f32, @floatFromInt(self.buffer.lineCount())) * self.cell_height;
        const max_scroll_y = @max(0, total_h - view_h);
        self.scroll_y = @min(self.scroll_y, max_scroll_y);

        // Horizontal: find longest visible line length
        const first_line: u32 = @intFromFloat(@max(0, self.scroll_y / self.cell_height));
        const visible: u32 = @intFromFloat(view_h / self.cell_height);
        const last_line = @min(first_line + visible + 2, self.buffer.lineCount());
        var max_len: u32 = 0;
        var line = first_line;
        while (line < last_line) : (line += 1) {
            const ll = self.buffer.lineEnd(line) - self.buffer.lineStart(line);
            if (ll > max_len) max_len = ll;
        }
        const content_w = @as(f32, @floatFromInt(max_len)) * self.cell_width;
        const max_scroll_x = @max(0, content_w - view_w);
        self.scroll_x = @min(self.scroll_x, max_scroll_x);
    }

    pub fn click(self: *Editor, x: f32, y: f32, extend: bool) void {
        // Account for line number gutter
        const gutter_width = self.gutterWidth();
        const text_x = @max(0, x - gutter_width);

        const col: u32 = @intFromFloat(@max(0, (text_x + self.scroll_x) / self.cell_width));
        const line: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
        const max_line = self.buffer.lineCount() -| 1;
        const clamped_line = @min(line, max_line);

        if (extend) {
            self.startSelectionIfNeeded();
        } else {
            self.selection.clear();
        }

        self.cursor.moveTo(clamped_line, col);
        self.clampCursorCol();
    }

    // ── Multi-click ─────────────────────────────────────────────

    pub fn doubleClick(self: *Editor, x: f32, y: f32) void {
        const pos = self.screenToLineCol(x, y);
        self.selectWordAt(pos.line, pos.col);
    }

    pub fn tripleClick(self: *Editor, x: f32, y: f32) void {
        const pos = self.screenToLineCol(x, y);
        self.selectLineAt(pos.line);
    }

    fn selectWordAt(self: *Editor, line: u32, col: u32) void {
        const clamped_line = @min(line, self.buffer.lineCount() -| 1);
        const line_start = self.buffer.lineStart(clamped_line);
        const line_end = self.buffer.lineEnd(clamped_line);
        const line_len = line_end - line_start;
        const clamped_col = @min(col, line_len);

        var start = clamped_col;
        while (start > 0) {
            const b = self.buffer.byteAt(line_start + start - 1) orelse break;
            if (isWordSeparator(b) or b == '\n') break;
            start -= 1;
        }

        var end = clamped_col;
        while (end < line_len) {
            const b = self.buffer.byteAt(line_start + end) orelse break;
            if (isWordSeparator(b) or b == '\n') break;
            end += 1;
        }

        if (start == end) {
            // On whitespace/separator — select the separator run instead
            start = clamped_col;
            end = clamped_col;
            while (start > 0) {
                const b = self.buffer.byteAt(line_start + start - 1) orelse break;
                if (!isWordSeparator(b) or b == '\n') break;
                start -= 1;
            }
            while (end < line_len) {
                const b = self.buffer.byteAt(line_start + end) orelse break;
                if (!isWordSeparator(b) or b == '\n') break;
                end += 1;
            }
        }

        self.selection.setAnchor(clamped_line, start);
        self.cursor.moveTo(clamped_line, end);
    }

    fn selectLineAt(self: *Editor, line: u32) void {
        const clamped_line = @min(line, self.buffer.lineCount() -| 1);
        self.selection.setAnchor(clamped_line, 0);
        if (clamped_line < self.buffer.lineCount() -| 1) {
            self.cursor.moveTo(clamped_line + 1, 0);
        } else {
            const line_len = self.buffer.lineEnd(clamped_line) - self.buffer.lineStart(clamped_line);
            self.cursor.moveTo(clamped_line, line_len);
        }
    }

    // ── Bracket matching ────────────────────────────────────────

    pub const LineCol = struct { line: u32, col: u32 };

    pub fn findMatchingBracket(self: *const Editor) ?LineCol {
        const line_start = self.buffer.lineStart(self.cursor.line);
        // Check character at cursor and before cursor
        const at_cursor = self.buffer.byteAt(line_start + self.cursor.col);
        const before_cursor = if (self.cursor.col > 0) self.buffer.byteAt(line_start + self.cursor.col - 1) else null;

        if (at_cursor) |ch| {
            if (bracketInfo(ch)) |info| {
                return self.scanForBracket(self.cursor.line, self.cursor.col, info.match, info.forward);
            }
        }
        if (before_cursor) |ch| {
            if (bracketInfo(ch)) |info| {
                return self.scanForBracket(self.cursor.line, self.cursor.col - 1, info.match, info.forward);
            }
        }
        return null;
    }

    const BracketInfo = struct { match: u8, forward: bool };

    fn bracketInfo(ch: u8) ?BracketInfo {
        return switch (ch) {
            '(' => .{ .match = ')', .forward = true },
            '[' => .{ .match = ']', .forward = true },
            '{' => .{ .match = '}', .forward = true },
            ')' => .{ .match = '(', .forward = false },
            ']' => .{ .match = '[', .forward = false },
            '}' => .{ .match = '{', .forward = false },
            else => null,
        };
    }

    fn scanForBracket(self: *const Editor, start_line: u32, start_col: u32, target: u8, forward: bool) ?LineCol {
        const start_pos = self.buffer.lineStart(start_line) + start_col;
        const open_ch = self.buffer.byteAt(start_pos) orelse return null;
        var depth: i32 = 0;
        const total = self.buffer.totalLength();

        if (forward) {
            var pos = start_pos;
            while (pos < total) : (pos += 1) {
                const b = self.buffer.byteAt(pos) orelse break;
                if (b == open_ch) {
                    depth += 1;
                } else if (b == target) {
                    depth -= 1;
                    if (depth == 0) {
                        const lc = self.buffer.posToLineCol(pos);
                        return .{ .line = lc.line, .col = lc.col };
                    }
                }
            }
        } else {
            var pos: i64 = @intCast(start_pos);
            while (pos >= 0) : (pos -= 1) {
                const b = self.buffer.byteAt(@intCast(pos)) orelse break;
                if (b == open_ch) {
                    depth += 1;
                } else if (b == target) {
                    depth -= 1;
                    if (depth == 0) {
                        const lc = self.buffer.posToLineCol(@intCast(pos));
                        return .{ .line = lc.line, .col = lc.col };
                    }
                }
            }
        }
        return null;
    }

    fn screenToLineCol(self: *const Editor, x: f32, y: f32) LineCol {
        const gutter_w = self.gutterWidth();
        const text_x = @max(0, x - gutter_w);
        const col: u32 = @intFromFloat(@max(0, (text_x + self.scroll_x) / self.cell_width));
        const line: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
        const max_line = self.buffer.lineCount() -| 1;
        return .{ .line = @min(line, max_line), .col = col };
    }

    // ── Find & Replace ──────────────────────────────────────────

    pub fn findNext(self: *Editor, query: []const u8) bool {
        if (query.len == 0) return false;
        const total = self.buffer.totalLength();
        if (total == 0) return false;

        // Start searching from position after cursor
        const start_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        var search_pos = if (self.selection.active) start_pos else start_pos;

        // Search forward from cursor, wrapping around
        var checked: u32 = 0;
        while (checked < total) {
            if (search_pos >= total) search_pos = 0;
            const b = self.buffer.byteAt(search_pos) orelse break;
            if (b == query[0]) {
                if (self.matchAt(search_pos, query)) {
                    const start_lc = self.buffer.posToLineCol(search_pos);
                    const end_pos = search_pos + @as(u32, @intCast(query.len));
                    const end_lc = self.buffer.posToLineCol(end_pos);
                    self.selection.setAnchor(start_lc.line, start_lc.col);
                    self.cursor.moveTo(end_lc.line, end_lc.col);
                    self.ensureCursorVisible();
                    return true;
                }
            }
            search_pos += 1;
            checked += 1;
        }
        return false;
    }

    pub fn findPrev(self: *Editor, query: []const u8) bool {
        if (query.len == 0) return false;
        const total = self.buffer.totalLength();
        if (total == 0) return false;

        const cursor_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        // Start from before selection start if active
        var start: i64 = undefined;
        if (self.selection.active) {
            const r = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            start = @as(i64, self.buffer.lineColToPos(r.start_line, r.start_col)) - 1;
        } else {
            start = @as(i64, cursor_pos) - 1;
        }
        if (start < 0) start = @as(i64, total) - 1;

        var checked: u32 = 0;
        while (checked < total) {
            if (start < 0) start = @as(i64, total) - 1;
            const pos: u32 = @intCast(start);
            const b = self.buffer.byteAt(pos) orelse break;
            if (b == query[0]) {
                if (self.matchAt(pos, query)) {
                    const start_lc = self.buffer.posToLineCol(pos);
                    const end_pos = pos + @as(u32, @intCast(query.len));
                    const end_lc = self.buffer.posToLineCol(end_pos);
                    self.selection.setAnchor(start_lc.line, start_lc.col);
                    self.cursor.moveTo(end_lc.line, end_lc.col);
                    self.ensureCursorVisible();
                    return true;
                }
            }
            start -= 1;
            checked += 1;
        }
        return false;
    }

    pub fn replaceNext(self: *Editor, query: []const u8, replacement: []const u8) !bool {
        // If current selection matches query, replace it, then find next
        if (self.selection.active) {
            const sel_text = self.getSelectionText();
            if (sel_text) |text| {
                defer self.allocator.free(text);
                if (std.mem.eql(u8, text, query)) {
                    try self.deleteSelection();
                    try self.insertText(replacement);
                    _ = self.findNext(query);
                    return true;
                }
            }
        }
        // Otherwise just find next
        return self.findNext(query);
    }

    pub fn replaceAll(self: *Editor, query: []const u8, replacement: []const u8) !u32 {
        if (query.len == 0) return 0;
        var count: u32 = 0;

        // Move to start
        self.cursor.moveTo(0, 0);
        self.selection.clear();

        while (self.findNext(query)) {
            try self.deleteSelection();
            try self.insertText(replacement);
            count += 1;
            // Safety: prevent infinite loop if replacement contains query
            if (count > 100_000) break;
        }
        return count;
    }

    fn matchAt(self: *const Editor, pos: u32, query: []const u8) bool {
        const total = self.buffer.totalLength();
        if (pos + @as(u32, @intCast(query.len)) > total) return false;
        for (query, 0..) |qch, i| {
            const b = self.buffer.byteAt(pos + @as(u32, @intCast(i))) orelse return false;
            if (b != qch) return false;
        }
        return true;
    }

    // ── Render ─────────────────────────────────────────────────

    pub fn prepareRender(self: *Editor) void {
        self.render_state.compute(self);
    }

    pub fn gutterWidth(self: *const Editor) f32 {
        if (!self.config.line_numbers) return 0;
        // Width for line numbers: digits * cell_width + padding
        const total_lines = self.buffer.lineCount();
        var digits: u32 = 1;
        var n = total_lines;
        while (n >= 10) : (n /= 10) {
            digits += 1;
        }
        digits = @max(digits, 3); // minimum 3 digits wide
        return @as(f32, @floatFromInt(digits + 1)) * self.cell_width;
    }

    // ── Internal cursor helpers ────────────────────────────────

    fn moveCursorLeft(self: *Editor) void {
        if (self.cursor.col > 0) {
            self.cursor.moveTo(self.cursor.line, self.cursor.col - 1);
        } else if (self.cursor.line > 0) {
            self.cursor.line -= 1;
            const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
            self.cursor.moveTo(self.cursor.line, line_len);
        }
        self.ensureCursorVisible();
    }

    fn moveCursorRight(self: *Editor) void {
        const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
        if (self.cursor.col < line_len) {
            self.cursor.moveTo(self.cursor.line, self.cursor.col + 1);
        } else if (self.cursor.line < self.buffer.lineCount() -| 1) {
            self.cursor.moveTo(self.cursor.line + 1, 0);
        }
        self.ensureCursorVisible();
    }

    fn moveCursorUp(self: *Editor) void {
        if (self.cursor.line > 0) {
            self.cursor.moveToKeepTarget(self.cursor.line - 1, self.cursor.target_col);
            self.clampCursorCol();
        }
        self.ensureCursorVisible();
    }

    fn moveCursorDown(self: *Editor) void {
        if (self.cursor.line < self.buffer.lineCount() -| 1) {
            self.cursor.moveToKeepTarget(self.cursor.line + 1, self.cursor.target_col);
            self.clampCursorCol();
        }
        self.ensureCursorVisible();
    }

    fn moveCursorWordLeft(self: *Editor) void {
        var pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        if (pos == 0) return;

        // Skip whitespace
        pos -= 1;
        while (pos > 0) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos -= 1;
        }
        // Skip word characters
        while (pos > 0) {
            const b = self.buffer.byteAt(pos - 1) orelse break;
            if (isWordSeparator(b)) break;
            pos -= 1;
        }

        const lc = self.buffer.posToLineCol(pos);
        self.cursor.moveTo(lc.line, lc.col);
        self.ensureCursorVisible();
    }

    fn moveCursorWordRight(self: *Editor) void {
        var pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const total = self.buffer.totalLength();
        if (pos >= total) return;

        // Skip current word characters
        while (pos < total) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (isWordSeparator(b)) break;
            pos += 1;
        }
        // Skip whitespace
        while (pos < total) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos += 1;
        }

        const lc = self.buffer.posToLineCol(pos);
        self.cursor.moveTo(lc.line, lc.col);
        self.ensureCursorVisible();
    }

    fn isWordSeparator(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
            ch == '.' or ch == ',' or ch == ';' or ch == ':' or
            ch == '(' or ch == ')' or ch == '[' or ch == ']' or
            ch == '{' or ch == '}' or ch == '<' or ch == '>' or
            ch == '"' or ch == '\'' or ch == '/' or ch == '\\';
    }

    fn clampCursorCol(self: *Editor) void {
        const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
        if (self.cursor.col > line_len) {
            self.cursor.col = line_len;
        }
    }

    fn visibleLines(self: *const Editor) u32 {
        if (self.cell_height <= 0) return 20;
        return @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.viewport_height)) / self.cell_height)));
    }

    fn ensureCursorVisible(self: *Editor) void {
        const cursor_y = @as(f32, @floatFromInt(self.cursor.line)) * self.cell_height;
        const cursor_x = @as(f32, @floatFromInt(self.cursor.col)) * self.cell_width;
        const view_h = @as(f32, @floatFromInt(self.viewport_height));
        const view_w = @as(f32, @floatFromInt(self.viewport_width)) - self.gutterWidth();

        // Vertical scrolling
        if (cursor_y < self.scroll_y) {
            self.scroll_y = cursor_y;
        } else if (cursor_y + self.cell_height > self.scroll_y + view_h) {
            self.scroll_y = cursor_y + self.cell_height - view_h;
        }

        // Horizontal scrolling
        if (cursor_x < self.scroll_x) {
            self.scroll_x = cursor_x;
        } else if (cursor_x + self.cell_width > self.scroll_x + view_w) {
            self.scroll_x = cursor_x + self.cell_width - view_w;
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────
const testing = std.testing;

test "Editor: basic insert and cursor" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("hello");
    try testing.expectEqual(@as(u32, 0), ed.cursor.line);
    try testing.expectEqual(@as(u32, 5), ed.cursor.col);
    try testing.expectEqual(@as(u32, 5), ed.buffer.totalLength());
}

test "Editor: newline and movement" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("line1");
    try ed.newline();
    try ed.insertText("line2");

    try testing.expectEqual(@as(u32, 1), ed.cursor.line);
    try testing.expectEqual(@as(u32, 5), ed.cursor.col);

    ed.moveUp();
    try testing.expectEqual(@as(u32, 0), ed.cursor.line);

    ed.moveDown();
    try testing.expectEqual(@as(u32, 1), ed.cursor.line);
}

test "Editor: delete backward" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("hello");
    try ed.deleteBackward();

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hell", content);
}

test "Editor: undo/redo" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("hello");
    try ed.undo();

    try testing.expectEqual(@as(u32, 0), ed.buffer.totalLength());

    try ed.redo();
    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello", content);
}

test "Editor: selection and get text" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("hello world");
    ed.moveStart();
    // Select "hello"
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        ed.selectRight();
    }

    const sel_text = ed.getSelectionText();
    if (sel_text) |text| {
        defer ed.allocator.free(text);
        try testing.expectEqualStrings("hello", text);
    } else {
        return error.TestExpectedSelectionText;
    }
}
