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
    pub const FindOptions = struct {
        case_sensitive: bool = true,
        whole_word: bool = false,
    };

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
    filename_z: ?[:0]u8 = null, // cached null-terminated copy for C API
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
        if (self.filename_z) |z| self.allocator.free(z);
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
        self.max_visible_line_len = 0;
        self.edit_counter +%= 1;
        self.has_error = false;
        self.wrap_cache_edit_counter = 0xFFFFFFFF;
        if (self.filename_z) |z| self.allocator.free(z);
        self.filename_z = null;
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

        var new_buffer = try PieceTable.initWithContent(self.allocator, content);
        errdefer new_buffer.deinit();
        const new_filename = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(new_filename);

        const old_filename = if (self.filename_owned) self.filename else null;

        self.buffer.deinit();
        self.buffer = new_buffer;
        self.cursor = .{};
        self.selection = .{};
        self.undo_stack.deinit();
        self.undo_stack = UndoStack.init(self.allocator);
        self.modified = false;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.max_visible_line_len = 0;
        self.language = Language.detectFromFilename(path);
        self.edit_counter +%= 1;
        self.has_error = false;
        self.wrap_cache_edit_counter = 0xFFFFFFFF;
        self.filename = new_filename;
        self.filename_owned = true;
        if (self.filename_z) |z| self.allocator.free(z);
        self.filename_z = self.allocator.dupeZ(u8, new_filename) catch null;

        if (old_filename) |f| self.allocator.free(f);
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
            if (self.filename_z) |z| self.allocator.free(z);
            self.filename_z = self.allocator.dupeZ(u8, path) catch null;
        }
        self.modified = false;
    }

    // ── Editing ────────────────────────────────────────────────

    pub fn insertText(self: *Editor, text: []const u8) !void {
        try self.insertTextWithOptions(text, true);
    }

    fn insertTextLiteral(self: *Editor, text: []const u8) !void {
        try self.insertTextWithOptions(text, false);
    }

    fn insertTextWithOptions(self: *Editor, text: []const u8, allow_auto_pair: bool) !void {
        if (allow_auto_pair and try self.handleAutoPair(text)) return;

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

    pub fn deleteWordBackward(self: *Editor) !void {
        if (self.selection.active) {
            try self.deleteSelection();
            return;
        }

        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const start_pos = self.wordBoundaryLeft(pos);
        if (start_pos == pos) return;

        const deleted = try self.buffer.getRange(self.allocator, start_pos, pos);
        defer self.allocator.free(deleted);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, start_pos, deleted);
        try self.buffer.delete(start_pos, pos - start_pos);
        try self.undo_stack.commit();

        const lc = self.buffer.posToLineCol(start_pos);
        self.cursor.moveTo(lc.line, lc.col);
        self.modified = true;
        self.edit_counter +%= 1;
        self.ensureCursorVisible();
    }

    pub fn deleteWordForward(self: *Editor) !void {
        if (self.selection.active) {
            try self.deleteSelection();
            return;
        }

        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const end_pos = self.wordBoundaryRight(pos);
        if (end_pos == pos) return;

        const deleted = try self.buffer.getRange(self.allocator, pos, end_pos);
        defer self.allocator.free(deleted);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.delete, pos, deleted);
        try self.buffer.delete(pos, end_pos - pos);
        try self.undo_stack.commit();

        self.modified = true;
        self.edit_counter +%= 1;
        self.ensureCursorVisible();
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
            const space_count: u32 = @min(self.config.tab_size, 16);
            const indent_text = if (self.config.insert_spaces) spaces[0..space_count] else "\t";
            const indent_width: u32 = @intCast(indent_text.len);
            var applied_lines: u32 = 0;

            self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
            errdefer {
                while (applied_lines > 0) {
                    applied_lines -= 1;
                    const line_num = range.start_line + applied_lines;
                    const ls = self.buffer.lineStart(line_num);
                    self.buffer.delete(ls, indent_width) catch {};
                }
                self.undo_stack.discardCurrentGroup();
            }

            var line = range.start_line;
            while (line <= range.end_line) : (line += 1) {
                const ls = self.buffer.lineStart(line);
                try self.undo_stack.record(.insert, ls, indent_text);
                try self.buffer.insert(ls, indent_text);
                applied_lines += 1;
            }

            try self.undo_stack.commit();
            self.modified = true;
            self.edit_counter +%= 1;
            self.cursor.col += indent_width;
            self.cursor.target_col = self.cursor.col;
            self.selection.anchor_col += indent_width;
            self.ensureCursorVisible();
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
        const DedentChange = struct {
            line: u32,
            removed: []u8,
        };

        var start_line = self.cursor.line;
        var end_line = self.cursor.line;
        if (self.selection.active) {
            const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            start_line = range.start_line;
            end_line = range.end_line;
        }

        const tab = self.config.tab_size;
        const max_changes = end_line - start_line + 1;
        const changes = try self.allocator.alloc(DedentChange, max_changes);
        defer self.allocator.free(changes);
        var change_count: usize = 0;

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
                changes[change_count] = .{
                    .line = line,
                    .removed = try self.buffer.getRange(self.allocator, ls, ls + remove),
                };
                change_count += 1;
            }
        }
        defer {
            for (changes[0..change_count]) |change| {
                self.allocator.free(change.removed);
            }
        }

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        var applied_changes: usize = 0;
        errdefer {
            while (applied_changes > 0) {
                applied_changes -= 1;
                const change = changes[applied_changes];
                const ls = self.buffer.lineStart(change.line);
                self.buffer.insert(ls, change.removed) catch {};
            }
            self.undo_stack.discardCurrentGroup();
        }

        for (changes[0..change_count]) |change| {
            const remove: u32 = @intCast(change.removed.len);
            const ls = self.buffer.lineStart(change.line);
            try self.undo_stack.record(.delete, ls, change.removed);
            try self.buffer.delete(ls, remove);
            applied_changes += 1;

            if (self.cursor.line == change.line) {
                self.cursor.col -|= remove;
            }
            if (self.selection.active and self.selection.anchor_line == change.line) {
                self.selection.anchor_col -|= remove;
            }
        }

        if (change_count > 0) {
            try self.undo_stack.commit();
            self.modified = true;
            self.edit_counter +%= 1;
        }
        self.cursor.target_col = self.cursor.col;
        self.ensureCursorVisible();
    }

    pub fn toggleComment(self: *Editor) !void {
        const prefix = self.language.lineCommentPrefix() orelse return;
        const line_range = self.selectedLineRange();
        const line_count = self.buffer.lineCount();
        const start_line = @min(line_range.start_line, line_count -| 1);
        const end_line = @min(line_range.end_line, line_count -| 1);

        // Determine whether to comment or uncomment
        var has_content_line = false;
        var should_uncomment = true;
        {
            var li = start_line;
            while (li <= end_line) : (li += 1) {
                const ls = self.buffer.lineStart(li);
                const le = self.buffer.lineEnd(li);
                const indent = self.lineIndentBytes(ls, le);
                if (indent == le - ls) continue; // blank line
                has_content_line = true;
                if (!self.bufferStartsWith(ls + indent, prefix)) {
                    should_uncomment = false;
                    break;
                }
            }
        }
        if (!has_content_line) return;

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);

        var cursor_col_delta: i32 = 0;
        var anchor_col_delta: i32 = 0;
        const prefix_len: u32 = @intCast(prefix.len);

        // Process lines in reverse order to preserve byte positions
        var li = end_line;
        while (true) {
            const ls = self.buffer.lineStart(li);
            const le = self.buffer.lineEnd(li);
            const indent = self.lineIndentBytes(ls, le);

            if (indent != le - ls) { // skip blank lines
                const prefix_start = ls + indent;
                if (should_uncomment) {
                    // Delete comment prefix (and optional trailing space)
                    var remove_len: u32 = prefix_len;
                    if (self.buffer.byteAt(prefix_start + remove_len)) |b| {
                        if (b == ' ') remove_len += 1;
                    }
                    const removed = try self.buffer.getRange(self.allocator, prefix_start, prefix_start + remove_len);
                    defer self.allocator.free(removed);
                    try self.undo_stack.record(.delete, prefix_start, removed);
                    try self.buffer.delete(prefix_start, remove_len);

                    if (li == self.cursor.line and self.cursor.col > indent) {
                        const delta = @min(remove_len, self.cursor.col - indent);
                        cursor_col_delta = -@as(i32, @intCast(delta));
                    }
                    if (self.selection.active and li == self.selection.anchor_line and self.selection.anchor_col > indent) {
                        const delta = @min(remove_len, self.selection.anchor_col - indent);
                        anchor_col_delta = -@as(i32, @intCast(delta));
                    }
                } else {
                    // Insert comment prefix + space
                    var insert_buf: [16]u8 = undefined;
                    @memcpy(insert_buf[0..prefix.len], prefix);
                    insert_buf[prefix.len] = ' ';
                    const insert_text = insert_buf[0 .. prefix.len + 1];

                    try self.undo_stack.record(.insert, prefix_start, insert_text);
                    try self.buffer.insert(prefix_start, insert_text);

                    const added: u32 = @intCast(insert_text.len);
                    if (li == self.cursor.line and self.cursor.col >= indent) {
                        cursor_col_delta = @intCast(added);
                    }
                    if (self.selection.active and li == self.selection.anchor_line and self.selection.anchor_col >= indent) {
                        anchor_col_delta = @intCast(added);
                    }
                }
            }

            if (li == start_line) break;
            li -= 1;
        }

        try self.undo_stack.commit();
        self.modified = true;
        self.edit_counter +%= 1;

        // Adjust cursor and anchor columns
        if (cursor_col_delta < 0) {
            self.cursor.col -|= @intCast(@abs(cursor_col_delta));
        } else {
            self.cursor.col +|= @intCast(@as(u32, @intCast(cursor_col_delta)));
        }
        self.cursor.target_col = self.cursor.col;

        if (self.selection.active) {
            if (anchor_col_delta < 0) {
                self.selection.anchor_col -|= @intCast(@abs(anchor_col_delta));
            } else {
                self.selection.anchor_col +|= @intCast(@as(u32, @intCast(anchor_col_delta)));
            }
        }
        self.ensureCursorVisible();
    }

    pub fn duplicateLine(self: *Editor) !void {
        const line_range = self.selectedLineRange();
        const line_count = self.buffer.lineCount();
        const end_line = @min(line_range.end_line, line_count - 1);

        const range_start = self.buffer.lineStart(line_range.start_line);
        const range_end = self.buffer.lineEnd(end_line);

        // Get range content (without trailing \n of last line)
        const range_content = try self.buffer.getRange(self.allocator, range_start, range_end);
        defer self.allocator.free(range_content);

        // Check if there's a newline after the range
        const has_trailing_nl = if (self.buffer.byteAt(range_end)) |b| b == '\n' else false;

        const insert_len: u32 = @intCast(range_content.len + 1);
        const insert_text = try self.allocator.alloc(u8, insert_len);
        defer self.allocator.free(insert_text);

        const insert_pos: u32 = if (has_trailing_nl) range_end + 1 else range_end;

        if (has_trailing_nl) {
            // Insert "content\n" after the trailing newline
            @memcpy(insert_text[0..range_content.len], range_content);
            insert_text[range_content.len] = '\n';
        } else {
            // Last line of document: insert "\ncontent"
            insert_text[0] = '\n';
            @memcpy(insert_text[1..], range_content);
        }

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);
        try self.undo_stack.record(.insert, insert_pos, insert_text);
        try self.buffer.insert(insert_pos, insert_text);
        try self.undo_stack.commit();

        self.modified = true;
        self.edit_counter +%= 1;

        const line_delta = end_line - line_range.start_line + 1;
        self.cursor.moveTo(self.cursor.line + line_delta, self.cursor.col);
        if (self.selection.active) {
            self.selection.anchor_line += line_delta;
        }
        self.ensureCursorVisible();
    }

    pub fn moveLineUp(self: *Editor) !void {
        const line_range = self.selectedLineRange();
        if (line_range.start_line == 0) return;

        const above = line_range.start_line - 1;
        const above_start = self.buffer.lineStart(above);
        const above_end = self.buffer.lineEnd(above);
        // above line always has a trailing \n (since a line follows it)
        const delete_end = above_end + 1;
        const del_len = delete_end - above_start;

        const above_content = try self.buffer.getRange(self.allocator, above_start, above_end);
        defer self.allocator.free(above_content);

        const deleted_text = try self.buffer.getRange(self.allocator, above_start, delete_end);
        defer self.allocator.free(deleted_text);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);

        // Step 1: Delete the above line (including its trailing \n)
        try self.undo_stack.record(.delete, above_start, deleted_text);
        try self.buffer.delete(above_start, del_len);

        // After deletion, our range shifted up by 1. Insert "\nabove_content" at end of our range.
        const new_end_line = line_range.end_line - 1;
        const insert_pos = self.buffer.lineEnd(new_end_line);

        const insert_text = try self.allocator.alloc(u8, above_content.len + 1);
        defer self.allocator.free(insert_text);
        insert_text[0] = '\n';
        @memcpy(insert_text[1..], above_content);

        try self.undo_stack.record(.insert, insert_pos, insert_text);
        try self.buffer.insert(insert_pos, insert_text);
        try self.undo_stack.commit();

        self.modified = true;
        self.edit_counter +%= 1;
        self.cursor.moveTo(self.cursor.line - 1, self.cursor.col);
        if (self.selection.active) {
            self.selection.anchor_line -= 1;
        }
        self.ensureCursorVisible();
    }

    pub fn moveLineDown(self: *Editor) !void {
        const line_range = self.selectedLineRange();
        const line_count = self.buffer.lineCount();
        if (line_range.end_line + 1 >= line_count) return;

        const below = line_range.end_line + 1;
        const del_start = self.buffer.lineEnd(line_range.end_line);
        const del_end = self.buffer.lineEnd(below);
        const del_len = del_end - del_start;

        // Get below line content (without its preceding \n)
        const below_start = self.buffer.lineStart(below);
        const below_content = try self.buffer.getRange(self.allocator, below_start, del_end);
        defer self.allocator.free(below_content);

        // Full deleted text for undo: "\nbelow_content"
        const deleted_text = try self.buffer.getRange(self.allocator, del_start, del_end);
        defer self.allocator.free(deleted_text);

        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);

        // Step 1: Delete "\nbelow_content"
        try self.undo_stack.record(.delete, del_start, deleted_text);
        try self.buffer.delete(del_start, del_len);

        // Step 2: Insert "below_content\n" at the start of our range
        const insert_pos = self.buffer.lineStart(line_range.start_line);
        const insert_text = try self.allocator.alloc(u8, below_content.len + 1);
        defer self.allocator.free(insert_text);
        @memcpy(insert_text[0..below_content.len], below_content);
        insert_text[below_content.len] = '\n';

        try self.undo_stack.record(.insert, insert_pos, insert_text);
        try self.buffer.insert(insert_pos, insert_text);
        try self.undo_stack.commit();

        self.modified = true;
        self.edit_counter +%= 1;
        self.cursor.moveTo(self.cursor.line + 1, self.cursor.col);
        if (self.selection.active) {
            self.selection.anchor_line += 1;
        }
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

    pub fn selectStart(self: *Editor) void {
        self.startSelectionIfNeeded();
        self.cursor.moveTo(0, 0);
        self.ensureCursorVisible();
    }

    pub fn selectEnd(self: *Editor) void {
        self.startSelectionIfNeeded();
        const last_line = self.buffer.lineCount() -| 1;
        const line_len = self.buffer.lineEnd(last_line) - self.buffer.lineStart(last_line);
        self.cursor.moveTo(last_line, line_len);
        self.ensureCursorVisible();
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
        try self.insertTextLiteral(text);
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
        return self.findNextWithOptions(query, .{});
    }

    pub fn findNextWithOptions(self: *Editor, query: []const u8, options: FindOptions) bool {
        if (query.len == 0) return false;
        const total = self.buffer.totalLength();
        if (total == 0) return false;
        const qlen: u32 = @intCast(query.len);
        if (qlen > total) return false;

        const content = self.buffer.getContent(self.allocator) catch return false;
        defer self.allocator.free(content);

        const cursor_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);

        // Phase 1: search forward from cursor_pos to end
        var pos = cursor_pos;
        while (pos + qlen <= total) : (pos += 1) {
            if (matchInContent(content, pos, query, options) and
                (!options.whole_word or isWholeWordInContent(content, pos, pos + qlen, total)))
            {
                self.selectMatchPos(pos, qlen);
                return true;
            }
        }
        // Phase 2: wrap around from 0 to cursor_pos
        pos = 0;
        while (pos < cursor_pos and pos + qlen <= total) : (pos += 1) {
            if (matchInContent(content, pos, query, options) and
                (!options.whole_word or isWholeWordInContent(content, pos, pos + qlen, total)))
            {
                self.selectMatchPos(pos, qlen);
                return true;
            }
        }
        return false;
    }

    pub fn findPrev(self: *Editor, query: []const u8) bool {
        return self.findPrevWithOptions(query, .{});
    }

    pub fn findPrevWithOptions(self: *Editor, query: []const u8, options: FindOptions) bool {
        if (query.len == 0) return false;
        const total = self.buffer.totalLength();
        if (total == 0) return false;
        const qlen: u32 = @intCast(query.len);
        if (qlen > total) return false;

        const content = self.buffer.getContent(self.allocator) catch return false;
        defer self.allocator.free(content);

        const max_start: u32 = total - qlen;

        // Determine search start position
        var search_start: u32 = undefined;
        if (self.selection.active) {
            const r = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            const sel_start = self.buffer.lineColToPos(r.start_line, r.start_col);
            search_start = if (sel_start > 0) @min(sel_start - 1, max_start) else max_start;
        } else {
            const cursor_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
            search_start = if (cursor_pos > 0) @min(cursor_pos - 1, max_start) else max_start;
        }

        // Phase 1: search backward from search_start to 0
        var pos_signed: i64 = @intCast(search_start);
        while (pos_signed >= 0) : (pos_signed -= 1) {
            const p: u32 = @intCast(pos_signed);
            if (matchInContent(content, p, query, options) and
                (!options.whole_word or isWholeWordInContent(content, p, p + qlen, total)))
            {
                self.selectMatchPos(p, qlen);
                return true;
            }
        }
        // Phase 2: wrap around from max_start down to search_start + 1
        if (search_start < max_start) {
            pos_signed = @intCast(max_start);
            while (pos_signed > @as(i64, search_start)) : (pos_signed -= 1) {
                const p: u32 = @intCast(pos_signed);
                if (matchInContent(content, p, query, options) and
                    (!options.whole_word or isWholeWordInContent(content, p, p + qlen, total)))
                {
                    self.selectMatchPos(p, qlen);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn replaceNext(self: *Editor, query: []const u8, replacement: []const u8) !bool {
        return self.replaceNextWithOptions(query, replacement, .{});
    }

    pub fn replaceNextWithOptions(self: *Editor, query: []const u8, replacement: []const u8, options: FindOptions) !bool {
        if (self.selection.active) {
            const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            const start_pos = self.buffer.lineColToPos(range.start_line, range.start_col);
            const end_pos = self.buffer.lineColToPos(range.end_line, range.end_col);
            const sel_text = self.getSelectionText();
            if (sel_text) |text| {
                defer self.allocator.free(text);
                if (bytesEqual(text, query, options.case_sensitive) and
                    (!options.whole_word or self.isWholeWordMatch(start_pos, end_pos)))
                {
                    try self.deleteSelection();
                    try self.insertTextLiteral(replacement);
                    _ = self.findNextWithOptions(query, options);
                    return true;
                }
            }
        }
        return self.findNextWithOptions(query, options);
    }

    pub fn replaceAll(self: *Editor, query: []const u8, replacement: []const u8) !u32 {
        return self.replaceAllWithOptions(query, replacement, .{});
    }

    pub fn replaceAllWithOptions(self: *Editor, query: []const u8, replacement: []const u8, options: FindOptions) !u32 {
        if (query.len == 0) return 0;
        var count: u32 = 0;

        self.cursor.moveTo(0, 0);
        self.selection.clear();

        var search_pos: u32 = 0;
        while (search_pos + @as(u32, @intCast(query.len)) <= self.buffer.totalLength()) {
            if (self.matchAt(search_pos, query, options)) {
                const start_lc = self.buffer.posToLineCol(search_pos);
                const end_lc = self.buffer.posToLineCol(search_pos + @as(u32, @intCast(query.len)));
                self.selection.setAnchor(start_lc.line, start_lc.col);
                self.cursor.moveTo(end_lc.line, end_lc.col);
                try self.deleteSelection();
                try self.insertTextLiteral(replacement);
                search_pos += @as(u32, @intCast(replacement.len));
                count += 1;
            } else {
                search_pos += 1;
            }
        }
        return count;
    }

    fn matchAt(self: *const Editor, pos: u32, query: []const u8, options: FindOptions) bool {
        const total = self.buffer.totalLength();
        if (pos + @as(u32, @intCast(query.len)) > total) return false;
        for (query, 0..) |qch, i| {
            const b = self.buffer.byteAt(pos + @as(u32, @intCast(i))) orelse return false;
            if (!byteEqual(b, qch, options.case_sensitive)) return false;
        }
        if (!options.whole_word) return true;
        return self.isWholeWordMatch(pos, pos + @as(u32, @intCast(query.len)));
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

    const LineRange = struct {
        start_line: u32,
        end_line: u32,
    };

    fn selectedLineRange(self: *const Editor) LineRange {
        if (!self.selection.active) {
            return .{ .start_line = self.cursor.line, .end_line = self.cursor.line };
        }

        const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
        var end_line = range.end_line;
        if (range.end_col == 0 and end_line > range.start_line) {
            end_line -= 1;
        }
        return .{ .start_line = range.start_line, .end_line = end_line };
    }

    fn handleAutoPair(self: *Editor, text: []const u8) !bool {
        if (text.len != 1) return false;

        const ch = text[0];
        const cursor_pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const next_byte = self.buffer.byteAt(cursor_pos);

        if (!self.selection.active and next_byte == ch and isAutoPairSkippable(ch)) {
            self.moveCursorRight();
            return true;
        }

        const closing = autoPairClosing(ch) orelse return false;
        self.undo_stack.setCursorBefore(self.cursor.line, self.cursor.col);

        if (self.selection.active) {
            const range = self.selection.orderedRange(self.cursor.line, self.cursor.col);
            const start_pos = self.buffer.lineColToPos(range.start_line, range.start_col);
            const end_pos = self.buffer.lineColToPos(range.end_line, range.end_col);
            const selected = try self.buffer.getRange(self.allocator, start_pos, end_pos);
            defer self.allocator.free(selected);

            const wrapped = try self.allocator.alloc(u8, selected.len + 2);
            defer self.allocator.free(wrapped);
            wrapped[0] = ch;
            @memcpy(wrapped[1 .. 1 + selected.len], selected);
            wrapped[wrapped.len - 1] = closing;

            try self.undo_stack.record(.delete, start_pos, selected);
            try self.buffer.delete(start_pos, end_pos - start_pos);
            try self.undo_stack.record(.insert, start_pos, wrapped);
            try self.buffer.insert(start_pos, wrapped);
            try self.undo_stack.commit();

            const end_lc = self.buffer.posToLineCol(start_pos + @as(u32, @intCast(wrapped.len)));
            self.selection.clear();
            self.cursor.moveTo(end_lc.line, end_lc.col);
        } else {
            var pair = [2]u8{ ch, closing };
            try self.undo_stack.record(.insert, cursor_pos, &pair);
            try self.buffer.insert(cursor_pos, &pair);
            try self.undo_stack.commit();

            const lc = self.buffer.posToLineCol(cursor_pos + 1);
            self.cursor.moveTo(lc.line, lc.col);
        }

        self.modified = true;
        self.edit_counter +%= 1;
        self.ensureCursorVisible();
        return true;
    }

    // ── Buffer query helpers ─────────────────────────────────────

    fn lineIndentBytes(self: *const Editor, start: u32, end: u32) u32 {
        var i: u32 = 0;
        while (start + i < end) {
            const b = self.buffer.byteAt(start + i) orelse break;
            if (b != ' ' and b != '\t') break;
            i += 1;
        }
        return i;
    }

    fn bufferStartsWith(self: *const Editor, pos: u32, prefix: []const u8) bool {
        for (prefix, 0..) |ch, i| {
            const b = self.buffer.byteAt(pos + @as(u32, @intCast(i))) orelse return false;
            if (b != ch) return false;
        }
        return true;
    }

    // ── Find helpers (content-buffer based) ──────────────────────

    fn selectMatchPos(self: *Editor, pos: u32, qlen: u32) void {
        const start_lc = self.buffer.posToLineCol(pos);
        const end_lc = self.buffer.posToLineCol(pos + qlen);
        self.selection.setAnchor(start_lc.line, start_lc.col);
        self.cursor.moveTo(end_lc.line, end_lc.col);
        self.ensureCursorVisible();
    }

    fn matchInContent(content: []const u8, pos: u32, query: []const u8, options: FindOptions) bool {
        const p: usize = pos;
        for (query, 0..) |qch, i| {
            if (!byteEqual(content[p + i], qch, options.case_sensitive)) return false;
        }
        return true;
    }

    fn isWholeWordInContent(content: []const u8, start: u32, end: u32, total: u32) bool {
        if (start > 0 and !isWordSeparator(content[start - 1])) return false;
        if (end < total and !isWordSeparator(content[end])) return false;
        return true;
    }

    fn autoPairClosing(ch: u8) ?u8 {
        return switch (ch) {
            '(' => ')',
            '[' => ']',
            '{' => '}',
            '"' => '"',
            '\'' => '\'',
            else => null,
        };
    }

    fn isAutoPairSkippable(ch: u8) bool {
        return switch (ch) {
            ')', ']', '}', '"', '\'' => true,
            else => false,
        };
    }

    fn wordBoundaryLeft(self: *const Editor, start_pos: u32) u32 {
        if (start_pos == 0) return 0;

        var pos = self.buffer.prevCodepointStart(start_pos);
        while (pos > 0) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos = self.buffer.prevCodepointStart(pos);
        }
        while (pos > 0) {
            const prev = self.buffer.prevCodepointStart(pos);
            const b = self.buffer.byteAt(prev) orelse break;
            if (isWordSeparator(b)) break;
            pos = prev;
        }
        return pos;
    }

    fn wordBoundaryRight(self: *const Editor, start_pos: u32) u32 {
        var pos = start_pos;
        const total = self.buffer.totalLength();
        if (pos >= total) return total;

        while (pos < total) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (isWordSeparator(b)) break;
            pos = self.buffer.nextCodepointStart(pos);
        }
        while (pos < total) {
            const b = self.buffer.byteAt(pos) orelse break;
            if (!isWordSeparator(b)) break;
            pos = self.buffer.nextCodepointStart(pos);
        }
        return pos;
    }

    fn byteEqual(a: u8, b: u8, case_sensitive: bool) bool {
        if (case_sensitive) return a == b;
        return foldAscii(a) == foldAscii(b);
    }

    fn bytesEqual(a: []const u8, b: []const u8, case_sensitive: bool) bool {
        if (a.len != b.len) return false;
        for (a, b) |lhs, rhs| {
            if (!byteEqual(lhs, rhs, case_sensitive)) return false;
        }
        return true;
    }

    fn foldAscii(ch: u8) u8 {
        return if (ch < 0x80) std.ascii.toLower(ch) else ch;
    }

    fn isWholeWordMatch(self: *const Editor, start_pos: u32, end_pos: u32) bool {
        if (start_pos > 0) {
            const before = self.buffer.byteAt(start_pos - 1) orelse return false;
            if (!isWordSeparator(before)) return false;
        }
        const after = self.buffer.byteAt(end_pos) orelse return true;
        return isWordSeparator(after);
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
        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const new_pos = self.wordBoundaryLeft(pos);
        if (new_pos == pos) return;

        const lc = self.buffer.posToLineCol(new_pos);
        self.cursor.moveTo(lc.line, lc.col);
        self.ensureCursorVisible();
    }

    fn moveCursorWordRight(self: *Editor) void {
        const pos = self.buffer.lineColToPos(self.cursor.line, self.cursor.col);
        const new_pos = self.wordBoundaryRight(pos);
        if (new_pos == pos) return;

        const lc = self.buffer.posToLineCol(new_pos);
        self.cursor.moveTo(lc.line, lc.col);
        self.ensureCursorVisible();
    }

    fn isWordByte(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
    }

    fn isWordSeparator(ch: u8) bool {
        return !isWordByte(ch);
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

fn expectContent(ed: *Editor, expected: []const u8) !void {
    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

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

test "Editor: openFile resets state and clears undo history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data = "loaded\ntext",
    });
    const path = try tmp.dir.realpathAlloc(testing.allocator, "sample.txt");
    defer testing.allocator.free(path);

    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("draft");
    ed.selectAll();
    ed.scroll_x = 42;
    ed.scroll_y = 24;

    try ed.openFile(path);

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("loaded\ntext", content);
    try testing.expectEqual(@as(u32, 0), ed.cursor.line);
    try testing.expectEqual(@as(u32, 0), ed.cursor.col);
    try testing.expect(!ed.selection.active);
    try testing.expect(!ed.modified);
    try testing.expectEqual(@as(f32, 0), ed.scroll_x);
    try testing.expectEqual(@as(f32, 0), ed.scroll_y);

    try ed.undo();
    const after_undo = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(after_undo);
    try testing.expectEqualStrings("loaded\ntext", after_undo);
}

test "Editor: openFile failure preserves current document" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const missing_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "missing.txt" });
    defer testing.allocator.free(missing_path);

    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("keep");
    try testing.expectError(error.FileNotFound, ed.openFile(missing_path));

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("keep", content);
    try testing.expectEqual(@as(u32, 0), ed.cursor.line);
    try testing.expectEqual(@as(u32, 4), ed.cursor.col);
}

test "Editor: replaceAll does not re-match inserted text" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("aba");
    const replaced = try ed.replaceAll("a", "aa");
    try testing.expectEqual(@as(u32, 2), replaced);

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("aabaa", content);
}

test "Editor: multi-line tab insert respects tab mode" {
    var config = Config.defaults();
    config.insert_spaces = false;
    config.tab_size = 4;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb");
    ed.selectAll();
    try ed.insertTab();

    const content = try ed.buffer.getContent(testing.allocator);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("\ta\n\tb", content);
    try testing.expectEqual(@as(u32, 1), ed.selection.anchor_col);
    try testing.expectEqual(@as(u32, 2), ed.cursor.col);
}

test "Editor: auto-pairs delimiters" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("(");
    try expectContent(&ed, "()");
    try testing.expectEqual(@as(u32, 1), ed.cursor.col);

    try ed.insertText(")");
    try expectContent(&ed, "()");
    try testing.expectEqual(@as(u32, 2), ed.cursor.col);
}

test "Editor: paste inserts delimiters literally" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.paste("(");

    try expectContent(&ed, "(");
    try testing.expectEqual(@as(u32, 1), ed.cursor.col);
}

test "Editor: auto-pair wraps selection" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("word");
    ed.selectAll();
    try ed.insertText("(");

    try expectContent(&ed, "(word)");
    try testing.expect(!ed.selection.active);
    try testing.expectEqual(@as(u32, 6), ed.cursor.col);
}

test "Editor: delete word backward and forward" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("foo bar");
    try ed.deleteWordBackward();
    try expectContent(&ed, "foo ");
    try testing.expectEqual(@as(u32, 4), ed.cursor.col);

    ed.moveStart();
    try ed.deleteWordForward();
    try expectContent(&ed, "");
    try testing.expectEqual(@as(u32, 0), ed.cursor.col);
}

test "Editor: toggleComment adds and removes line comments" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.language = .zig;
    try ed.insertText("    foo\n    bar");
    ed.selectAll();

    try ed.toggleComment();
    try expectContent(&ed, "    // foo\n    // bar");
    try testing.expectEqual(@as(u32, 10), ed.cursor.col);

    try ed.toggleComment();
    try expectContent(&ed, "    foo\n    bar");
    try testing.expectEqual(@as(u32, 7), ed.cursor.col);
}

test "Editor: toggleComment line selection excludes following line" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.language = .zig;
    try ed.insertText("foo\nbar");
    ed.selection.setAnchor(0, 0);
    ed.cursor.moveTo(1, 0);

    try ed.toggleComment();
    try expectContent(&ed, "// foo\nbar");
}

test "Editor: toggleComment clamps cursor inside removed prefix" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.language = .zig;
    try ed.insertText("    // foo");
    ed.cursor.moveTo(0, 5);

    try ed.toggleComment();
    try expectContent(&ed, "    foo");
    try testing.expectEqual(@as(u32, 4), ed.cursor.col);
}

test "Editor: toggleComment clamps selection anchor inside removed prefix" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.language = .zig;
    try ed.insertText("    // foo");
    ed.selection.setAnchor(0, 5);
    ed.cursor.moveTo(0, 8);

    try ed.toggleComment();
    try expectContent(&ed, "    foo");
    try testing.expect(ed.selection.active);
    try testing.expectEqual(@as(u32, 4), ed.selection.anchor_col);
    try testing.expectEqual(@as(u32, 5), ed.cursor.col);
}

test "Editor: duplicateLine duplicates current line" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb");
    ed.moveStart();

    try ed.duplicateLine();
    try expectContent(&ed, "a\na\nb");
    try testing.expectEqual(@as(u32, 1), ed.cursor.line);
    try testing.expectEqual(@as(u32, 0), ed.cursor.col);
}

test "Editor: duplicateLine duplicates selected block" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb");
    ed.selectAll();

    try ed.duplicateLine();
    try expectContent(&ed, "a\nb\na\nb");
    try testing.expect(ed.selection.active);
    try testing.expectEqual(@as(u32, 2), ed.selection.anchor_line);
    try testing.expectEqual(@as(u32, 3), ed.cursor.line);
}

test "Editor: duplicateLine line selection excludes following line" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb\nc");
    ed.selection.setAnchor(0, 0);
    ed.cursor.moveTo(1, 0);

    try ed.duplicateLine();
    try expectContent(&ed, "a\na\nb\nc");
}

test "Editor: moveLineDown moves current line" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb\nc");
    ed.moveStart();
    ed.moveDown();

    try ed.moveLineDown();
    try expectContent(&ed, "a\nc\nb");
    try testing.expectEqual(@as(u32, 2), ed.cursor.line);
}

test "Editor: moveLineDown line selection excludes following line" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb\nc");
    ed.selection.setAnchor(0, 0);
    ed.cursor.moveTo(1, 0);

    try ed.moveLineDown();
    try expectContent(&ed, "b\na\nc");
}

test "Editor: moveLineUp moves selected block" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a\nb\nc\nd");
    ed.selection.setAnchor(1, 0);
    ed.cursor.moveTo(2, 1);

    try ed.moveLineUp();
    try expectContent(&ed, "b\nc\na\nd");
    try testing.expectEqual(@as(u32, 0), ed.selection.anchor_line);
    try testing.expectEqual(@as(u32, 1), ed.cursor.line);
}

test "Editor: findNextWithOptions is case-insensitive" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("Hello hELLo");
    ed.moveStart();

    try testing.expect(ed.findNextWithOptions("hello", .{ .case_sensitive = false }));
    {
        const sel = ed.getSelectionText().?;
        defer ed.allocator.free(sel);
        try testing.expectEqualStrings("Hello", sel);
    }

    try testing.expect(ed.findNextWithOptions("hello", .{ .case_sensitive = false }));
    {
        const sel = ed.getSelectionText().?;
        defer ed.allocator.free(sel);
        try testing.expectEqualStrings("hELLo", sel);
    }
}

test "Editor: replaceNextWithOptions inserts literal replacement" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("a");
    ed.moveStart();
    try testing.expect(ed.findNextWithOptions("a", .{}));
    try testing.expect(try ed.replaceNextWithOptions("a", "(", .{}));

    try expectContent(&ed, "(");
}

test "Editor: replaceAllWithOptions inserts literal replacement" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("aba");
    const replaced = try ed.replaceAllWithOptions("a", "(", .{});

    try testing.expectEqual(@as(u32, 2), replaced);
    try expectContent(&ed, "(b(");
}

test "Editor: replaceAllWithOptions respects whole-word matching" {
    const config = Config.defaults();
    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    try ed.insertText("cat scatter Cat");
    const replaced = try ed.replaceAllWithOptions("cat", "dog", .{
        .case_sensitive = false,
        .whole_word = true,
    });

    try testing.expectEqual(@as(u32, 2), replaced);
    try expectContent(&ed, "dog scatter dog");
}
