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
    edit_counter: u32 = 0,

    // Render-computed max visible line length (set by RenderState.compute)
    max_visible_line_len: u32 = 0,

    // Syntax highlighting
    language: Language = .none,

    // Error feedback
    error_msg: [64]u8 = [_]u8{0} ** 64,
    has_error: bool = false,

    // Wrap cache: prefix_sums[i] = total visual rows for lines 0..i-1
    wrap_prefix_sums: std.ArrayListUnmanaged(u32) = .{},
    wrap_cache_edit_counter: u32 = 0xFFFFFFFF,
    wrap_cache_wrap_col: u32 = 0,

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
        self.wrap_prefix_sums.deinit(self.allocator);
        if (self.filename_owned) {
            if (self.filename) |f| self.allocator.free(f);
        }
    }

    // ── Error feedback ────────────────────────────────────────

    pub fn setLastError(self: *Editor, err: anyerror) void {
        const name = @errorName(err);
        const len = @min(name.len, 63);
        @memcpy(self.error_msg[0..len], name[0..len]);
        self.error_msg[len] = 0;
        self.has_error = true;
    }

    pub fn clearLastError(self: *Editor) void {
        self.has_error = false;
    }

    // ── File I/O ───────────────────────────────────────────────

    pub fn newFile(self: *Editor) void {
        self.buffer.deinit();
        self.buffer = PieceTable.init(self.allocator);
        self.cursor = .{};
        self.selection = .{};
        self.undo_stack.deinit();
        self.undo_stack = UndoStack.init(self.allocator);
        self.modified = false;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.language = .none;
        self.edit_counter +%= 1;
        self.has_error = false;
        self.wrap_cache_edit_counter = 0xFFFFFFFF;
        if (self.filename_owned) {
            if (self.filename) |f| self.allocator.free(f);
        }
        self.filename = null;
        self.filename_owned = false;
    }

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
        self.edit_counter +%= 1;

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

        // Find start of previous codepoint
        const prev_pos = self.buffer.prevCodepointStart(pos);
        const del_len = pos - prev_pos;

        // Get the bytes we're deleting for undo
        const del_bytes = try self.buffer.getRange(self.allocator, prev_pos, pos);
        defer self.allocator.free(del_bytes);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, prev_pos, del_bytes);

        try self.buffer.delete(prev_pos, del_len);
        self.modified = true;
        self.edit_counter +%= 1;

        // Move cursor to deletion point
        const lc = self.buffer.posToLineCol(prev_pos);
        self.cursor.moveTo(lc.line, lc.col);
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

        // Find end of codepoint at current position
        const next_pos = self.buffer.nextCodepointStart(pos);
        const del_len = next_pos - pos;

        const del_bytes = try self.buffer.getRange(self.allocator, pos, next_pos);
        defer self.allocator.free(del_bytes);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, pos, del_bytes);

        try self.buffer.delete(pos, del_len);
        self.modified = true;
        self.edit_counter +%= 1;

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
        self.edit_counter +%= 1;

        self.cursor.moveTo(range.start_line, range.start_col);
        self.selection.clear();

        try self.undo_stack.commit();
        self.ensureCursorVisible();
    }

    // ── Tab / Indent ──────────────────────────────────────────

    pub fn insertTab(self: *Editor) !void {
        if (self.selection.active) {
            const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            var spaces: [16]u8 = [_]u8{' '} ** 16;
            const n: u32 = @min(self.config.tab_size, 16);

            self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);

            var line = range.start_line;
            while (line <= range.end_line) : (line += 1) {
                const ls = self.buffer.lineStart(line);
                self.undo_stack.record(.insert, ls, spaces[0..n]) catch break;
                self.buffer.insert(ls, spaces[0..n]) catch break;
            }

            self.undo_stack.commit() catch {};
            self.modified = true;
            self.edit_counter +%= 1;
            self.cursor.col += n;
            self.cursor.target_col = self.cursor.col;
            self.selection.anchor_col += n;
        } else {
            var spaces: [16]u8 = [_]u8{' '} ** 16;
            const n = @min(self.config.tab_size, 16);
            if (self.config.insert_spaces) {
                try self.insertText(spaces[0..n]);
            } else {
                try self.insertText("\t");
            }
        }
    }

    pub fn dedent(self: *Editor) !void {
        var start_line = self.cursor.line;
        var end_line = self.cursor.line;
        if (self.selection.active) {
            const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            start_line = range.start_line;
            end_line = range.end_line;
        }

        const tab = self.config.tab_size;
        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        var did_change = false;

        var line = start_line;
        while (line <= end_line) : (line += 1) {
            const ls = self.buffer.lineStart(line);
            const le = self.buffer.lineEnd(line);
            var remove: u32 = 0;
            while (remove < tab and ls + remove < le) {
                const b = self.buffer.byteAt(ls + remove) orelse break;
                if (b == ' ') {
                    remove += 1;
                } else if (b == '\t') {
                    remove += 1;
                    break;
                } else break;
            }
            if (remove > 0) {
                const deleted = self.buffer.getRange(self.allocator, ls, ls + remove) catch break;
                defer self.allocator.free(deleted);
                self.undo_stack.record(.delete, ls, deleted) catch break;
                self.buffer.delete(ls, remove) catch break;
                did_change = true;

                if (self.cursor.line == line) {
                    self.cursor.col -|= remove;
                }
                if (self.selection.active and self.selection.anchor_line == line) {
                    self.selection.anchor_col -|= remove;
                }
            }
        }

        if (did_change) {
            self.undo_stack.commit() catch {};
            self.modified = true;
            self.edit_counter +%= 1;
        }
        self.cursor.target_col = self.cursor.col;
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
        self.edit_counter +%= 1;

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
        self.edit_counter +%= 1;

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
        if (self.config.wrap_lines) {
            self.scroll_y = @max(0, self.scroll_y + dy);
        } else {
            self.scroll_x = @max(0, self.scroll_x + dx);
            self.scroll_y = @max(0, self.scroll_y + dy);
        }
        self.clampScroll();
    }

    fn clampScroll(self: *Editor) void {
        const view_h = @as(f32, @floatFromInt(self.viewport_height));

        // Vertical: use visual rows when wrapping
        const total_vrows = if (self.config.wrap_lines) self.totalVisualRows() else self.buffer.lineCount();
        const total_h = @as(f32, @floatFromInt(total_vrows)) * self.cell_height;
        const max_scroll_y = @max(0, total_h - view_h);
        self.scroll_y = @min(self.scroll_y, max_scroll_y);

        // Horizontal: disabled when wrapping
        if (self.config.wrap_lines) {
            self.scroll_x = 0;
        } else {
            const gutter_w = self.gutterWidth();
            const view_w = @as(f32, @floatFromInt(self.viewport_width)) - gutter_w;
            const content_w = @as(f32, @floatFromInt(self.max_visible_line_len)) * self.cell_width;
            const max_scroll_x = @max(0, content_w - view_w);
            self.scroll_x = @min(self.scroll_x, max_scroll_x);
        }
    }

    pub fn click(self: *Editor, x: f32, y: f32, extend: bool) void {
        const gutter_width = self.gutterWidth();
        const text_x = @max(0, x - gutter_width);

        if (extend) {
            self.startSelectionIfNeeded();
        } else {
            self.selection.clear();
        }

        if (self.config.wrap_lines) {
            const vrow: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
            const result = self.visualRowToLine(vrow);
            const seg_vcol: u32 = @intFromFloat(@max(0, text_x / self.cell_width));
            const total_vcol = result.col_offset + seg_vcol;
            const byte_col = self.visualColToByteCol(result.line, total_vcol);
            self.cursor.moveTo(result.line, byte_col);
        } else {
            const vcol: u32 = @intFromFloat(@max(0, (text_x + self.scroll_x) / self.cell_width));
            const line: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
            const max_line = self.buffer.lineCount() -| 1;
            const clamped_line = @min(line, max_line);
            const byte_col = self.visualColToByteCol(clamped_line, vcol);
            self.cursor.moveTo(clamped_line, byte_col);
        }
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
        var line_len = line_end - line_start;
        // Exclude trailing newline from line length
        if (line_len > 0) {
            if (self.buffer.byteAt(line_start + line_len - 1)) |b| {
                if (b == '\n') line_len -= 1;
            }
        }

        // Empty line — just place cursor, no selection
        if (line_len == 0) {
            self.selection.clear();
            self.cursor.moveTo(clamped_line, 0);
            return;
        }

        const clamped_col = @min(col, line_len);

        var start = clamped_col;
        while (start > 0) {
            const b = self.buffer.byteAt(line_start + start - 1) orelse break;
            if (isWordSeparator(b)) break;
            start -= 1;
        }

        var end = clamped_col;
        while (end < line_len) {
            const b = self.buffer.byteAt(line_start + end) orelse break;
            if (isWordSeparator(b)) break;
            end += 1;
        }

        if (start == end) {
            // On whitespace/separator — select the separator run instead
            start = clamped_col;
            end = clamped_col;
            while (start > 0) {
                const b = self.buffer.byteAt(line_start + start - 1) orelse break;
                if (!isWordSeparator(b)) break;
                start -= 1;
            }
            while (end < line_len) {
                const b = self.buffer.byteAt(line_start + end) orelse break;
                if (!isWordSeparator(b)) break;
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

    fn screenToLineCol(self: *Editor, x: f32, y: f32) LineCol {
        const gutter_w = self.gutterWidth();
        const text_x = @max(0, x - gutter_w);

        if (self.config.wrap_lines) {
            const vrow: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
            const result = self.visualRowToLine(vrow);
            const seg_vcol: u32 = @intFromFloat(@max(0, text_x / self.cell_width));
            const total_vcol = result.col_offset + seg_vcol;
            const byte_col = self.visualColToByteCol(result.line, total_vcol);
            return .{ .line = result.line, .col = byte_col };
        } else {
            const vcol: u32 = @intFromFloat(@max(0, (text_x + self.scroll_x) / self.cell_width));
            const line: u32 = @intFromFloat(@max(0, (y + self.scroll_y) / self.cell_height));
            const max_line = self.buffer.lineCount() -| 1;
            const clamped_line = @min(line, max_line);
            const byte_col = self.visualColToByteCol(clamped_line, vcol);
            return .{ .line = clamped_line, .col = byte_col };
        }
    }

    // ── Find & Replace ──────────────────────────────────────────

    pub fn findNext(self: *Editor, query: []const u8) bool {
        if (query.len == 0) return false;
        const total = self.buffer.totalLength();
        if (total == 0) return false;

        // Start searching from after current selection/cursor
        const cursor_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        var search_pos = cursor_pos;

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

    // ── UTF-8 column helpers ─────────────────────────────────

    /// Convert byte column to visual column (codepoint count).
    pub fn byteColToVisualCol(self: *const Editor, line: u32, byte_col: u32) u32 {
        const line_start = self.buffer.lineStart(line);
        var pos: u32 = 0;
        var vcol: u32 = 0;
        while (pos < byte_col) {
            const b = self.buffer.byteAt(line_start + pos) orelse break;
            if (b == '\n') break;
            pos += PieceTable.codepointByteLen(b);
            vcol += 1;
        }
        return vcol;
    }

    /// Convert visual column to byte column.
    pub fn visualColToByteCol(self: *const Editor, line: u32, vcol: u32) u32 {
        const line_start = self.buffer.lineStart(line);
        const line_end = self.buffer.lineEnd(line);
        const line_len = line_end - line_start;
        var pos: u32 = 0;
        var v: u32 = 0;
        while (pos < line_len and v < vcol) {
            const b = self.buffer.byteAt(line_start + pos) orelse break;
            if (b == '\n') break;
            pos += PieceTable.codepointByteLen(b);
            v += 1;
        }
        return pos;
    }

    // ── Wrap helpers ──────────────────────────────────────────

    /// Wrap column in visual characters.
    pub fn wrapCol(self: *const Editor) u32 {
        const gutter_w = self.gutterWidth();
        const view_w = @as(f32, @floatFromInt(self.viewport_width)) - gutter_w;
        if (view_w <= 0 or self.cell_width <= 0) return 80;
        return @max(1, @as(u32, @intFromFloat(view_w / self.cell_width)));
    }

    /// Ensure the wrap prefix-sum cache is up to date.
    fn ensureWrapCache(self: *Editor) void {
        const wc = if (self.config.wrap_lines) self.wrapCol() else 0;
        if (self.wrap_cache_edit_counter == self.edit_counter and self.wrap_cache_wrap_col == wc) return;
        self.rebuildWrapCache(wc);
    }

    /// Rebuild wrap cache by scanning all piece bytes in one pass.
    fn rebuildWrapCache(self: *Editor, wc: u32) void {
        const line_count = self.buffer.lineCount();
        self.wrap_prefix_sums.clearRetainingCapacity();
        self.wrap_prefix_sums.ensureTotalCapacity(self.allocator, line_count + 1) catch return;

        if (!self.config.wrap_lines or wc == 0) {
            // No wrapping: visual row i = line i
            var i: u32 = 0;
            while (i <= line_count) : (i += 1) {
                self.wrap_prefix_sums.appendAssumeCapacity(i);
            }
        } else {
            self.wrap_prefix_sums.appendAssumeCapacity(0);
            var vcols: u32 = 0;
            var running: u32 = 0;

            var pi: usize = 0;
            while (pi < self.buffer.pieceCount()) : (pi += 1) {
                const slice = self.buffer.pieceBytes(pi);
                for (slice) |b| {
                    if (b == '\n') {
                        const vrows = if (vcols == 0) @as(u32, 1) else @max(1, (vcols + wc - 1) / wc);
                        running += vrows;
                        self.wrap_prefix_sums.append(self.allocator, running) catch return;
                        vcols = 0;
                    } else if (b < 0x80 or b >= 0xC0) {
                        vcols += 1;
                    }
                }
            }
            // Last line (no trailing newline)
            if (self.wrap_prefix_sums.items.len <= line_count) {
                const vrows = if (vcols == 0) @as(u32, 1) else @max(1, (vcols + wc - 1) / wc);
                running += vrows;
                self.wrap_prefix_sums.append(self.allocator, running) catch return;
            }
        }

        self.wrap_cache_edit_counter = self.edit_counter;
        self.wrap_cache_wrap_col = wc;
    }

    /// O(1): visual rows for a buffer line.
    pub fn lineVisualRows(self: *Editor, line: u32) u32 {
        if (!self.config.wrap_lines) return 1;
        self.ensureWrapCache();
        const sums = self.wrap_prefix_sums.items;
        if (line + 1 < sums.len) return sums[line + 1] - sums[line];
        return 1;
    }

    /// O(1): visual row index for the first row of a buffer line.
    pub fn lineToVisualRow(self: *Editor, target_line: u32) u32 {
        if (!self.config.wrap_lines) return target_line;
        self.ensureWrapCache();
        const sums = self.wrap_prefix_sums.items;
        if (target_line < sums.len) return sums[target_line];
        if (sums.len > 0) return sums[sums.len - 1];
        return target_line;
    }

    /// O(1): total visual rows in the document.
    pub fn totalVisualRows(self: *Editor) u32 {
        if (!self.config.wrap_lines) return self.buffer.lineCount();
        self.ensureWrapCache();
        const sums = self.wrap_prefix_sums.items;
        if (sums.len > 0) return sums[sums.len - 1];
        return self.buffer.lineCount();
    }

    /// O(log n): convert visual row to buffer line + visual column offset.
    pub fn visualRowToLine(self: *Editor, vrow: u32) struct { line: u32, col_offset: u32 } {
        if (!self.config.wrap_lines) return .{ .line = @min(vrow, self.buffer.lineCount() -| 1), .col_offset = 0 };
        self.ensureWrapCache();
        const sums = self.wrap_prefix_sums.items;
        if (sums.len < 2) return .{ .line = 0, .col_offset = 0 };

        // Binary search: largest i where sums[i] <= vrow
        var lo: u32 = 0;
        var hi: u32 = @intCast(sums.len - 2);
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (sums[mid] <= vrow) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        const segment = vrow -| sums[lo];
        return .{ .line = lo, .col_offset = segment * self.wrapCol() };
    }

    // ── Internal cursor helpers ────────────────────────────────

    fn moveCursorLeft(self: *Editor) void {
        if (self.cursor.col > 0) {
            const line_start = self.buffer.lineStart(self.cursor.line);
            const abs_pos = line_start + self.cursor.col;
            const prev_pos = self.buffer.prevCodepointStart(abs_pos);
            self.cursor.moveTo(self.cursor.line, if (prev_pos >= line_start) prev_pos - line_start else 0);
        } else if (self.cursor.line > 0) {
            self.cursor.line -= 1;
            const line_len = self.buffer.lineEnd(self.cursor.line) - self.buffer.lineStart(self.cursor.line);
            self.cursor.moveTo(self.cursor.line, line_len);
        }
        self.ensureCursorVisible();
    }

    fn moveCursorRight(self: *Editor) void {
        const line_start = self.buffer.lineStart(self.cursor.line);
        const line_len = self.buffer.lineEnd(self.cursor.line) - line_start;
        if (self.cursor.col < line_len) {
            const abs_pos = line_start + self.cursor.col;
            const next_pos = self.buffer.nextCodepointStart(abs_pos);
            const new_col = @min(next_pos - line_start, line_len);
            self.cursor.moveTo(self.cursor.line, new_col);
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

        // Step back one codepoint
        pos = self.buffer.prevCodepointStart(pos);
        // Skip separators
        while (pos > 0) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos = self.buffer.prevCodepointStart(pos);
        }
        // Find start of word
        while (pos > 0) {
            const prev = self.buffer.prevCodepointStart(pos);
            const b = self.buffer.byteAt(prev) orelse break;
            if (isWordSeparator(b)) break;
            pos = prev;
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
            pos = self.buffer.nextCodepointStart(pos);
        }
        // Skip separators
        while (pos < total) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos = self.buffer.nextCodepointStart(pos);
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
        const vcol = self.byteColToVisualCol(self.cursor.line, self.cursor.col);
        const view_h = @as(f32, @floatFromInt(self.viewport_height));
        const view_w = @as(f32, @floatFromInt(self.viewport_width)) - self.gutterWidth();

        if (self.config.wrap_lines) {
            const w = self.wrapCol();
            const base_vrow = self.lineToVisualRow(self.cursor.line);
            const seg: u32 = if (w > 0) vcol / w else 0;
            const cursor_vrow = base_vrow + seg;
            const cursor_y = @as(f32, @floatFromInt(cursor_vrow)) * self.cell_height;

            if (cursor_y < self.scroll_y) {
                self.scroll_y = cursor_y;
            } else if (cursor_y + self.cell_height > self.scroll_y + view_h) {
                self.scroll_y = cursor_y + self.cell_height - view_h;
            }
            self.scroll_x = 0;
        } else {
            const cursor_y = @as(f32, @floatFromInt(self.cursor.line)) * self.cell_height;
            const cursor_x = @as(f32, @floatFromInt(vcol)) * self.cell_width;

            if (cursor_y < self.scroll_y) {
                self.scroll_y = cursor_y;
            } else if (cursor_y + self.cell_height > self.scroll_y + view_h) {
                self.scroll_y = cursor_y + self.cell_height - view_h;
            }

            if (cursor_x < self.scroll_x) {
                self.scroll_x = cursor_x;
            } else if (cursor_x + self.cell_width > self.scroll_x + view_w) {
                self.scroll_x = cursor_x + self.cell_width - view_w;
            }
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

test "Editor: tab insert" {
    var config = Config.defaults();
    config.tab_size = 4;
    config.insert_spaces = true;
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertTab();
    try testing.expectEqual(@as(u32, 4), ed.cursor.col);

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("    ", content);
}

test "Editor: dedent" {
    var config = Config.defaults();
    config.tab_size = 4;
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("    hello");
    ed.moveLineStart();
    try ed.dedent();

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello", content);
}

test "Editor: UTF-8 delete backward" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    // Insert "hé" (h + 2-byte é)
    try ed.insertText("h\xC3\xA9");
    try testing.expectEqual(@as(u32, 3), ed.cursor.col); // 3 bytes

    try ed.deleteBackward();
    try testing.expectEqual(@as(u32, 1), ed.cursor.col); // back to 1 byte (h)

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("h", content);
}
