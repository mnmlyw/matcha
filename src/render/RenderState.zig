const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("Cell.zig");
const Lexer = @import("../highlight/Lexer.zig");
const Language = @import("../highlight/Language.zig").Language;
const PieceTable = @import("../buffer/PieceTable.zig").PieceTable;
const charWidth = @import("../buffer/UnicodeIterator.zig").charWidth;

const CellList = std.ArrayListUnmanaged(Cell.RenderCell);
const CursorList = std.ArrayListUnmanaged(Cell.RenderCursor);
const RectList = std.ArrayListUnmanaged(Cell.RenderRect);
const LineNumberList = std.ArrayListUnmanaged(Cell.RenderLineNumber);

const LineStateCache = struct {
    /// Cached line states at interval boundaries
    states: std.ArrayListUnmanaged(Lexer.LineState) = .{},
    /// Line number of each cached state (state[i] = state entering line interval*i)
    interval: u32 = 64,
    /// Total lines when cache was built
    cached_line_count: u32 = 0,
    /// Whether cache needs full rebuild
    dirty: bool = true,

    fn deinit(self: *LineStateCache, allocator: Allocator) void {
        self.states.deinit(allocator);
    }

    fn invalidate(self: *LineStateCache) void {
        self.dirty = true;
    }

    /// Get the cached state closest to (but not past) target_line.
    /// Returns the state and the line number it corresponds to.
    fn getNearest(self: *const LineStateCache, target_line: u32) struct { state: Lexer.LineState, from_line: u32 } {
        if (self.states.items.len == 0 or self.dirty) {
            return .{ .state = .{}, .from_line = 0 };
        }
        const idx = @min(target_line / self.interval, @as(u32, @intCast(self.states.items.len)) -| 1);
        return .{ .state = self.states.items[idx], .from_line = idx * self.interval };
    }
};

const LineTokenCacheEntry = struct {
    tokens: []Lexer.Token = &.{},
    end_state: Lexer.LineState = .{},
    valid: bool = false,

    fn deinit(self: *LineTokenCacheEntry, allocator: Allocator) void {
        if (self.tokens.len > 0) allocator.free(self.tokens);
        self.* = .{};
    }
};

const LineTokenCache = struct {
    entries: std.ArrayListUnmanaged(LineTokenCacheEntry) = .{},
    cached_line_count: u32 = 0,
    cached_language: Language = .none,
    cached_edit_counter: u32 = 0xFFFFFFFF,

    fn deinit(self: *LineTokenCache, allocator: Allocator) void {
        for (self.entries.items) |*entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    fn invalidate(self: *LineTokenCache, allocator: Allocator, line_count: u32, lang: Language, edit_counter: u32) void {
        for (self.entries.items) |*entry| {
            entry.deinit(allocator);
        }

        self.entries.clearRetainingCapacity();
        self.entries.ensureTotalCapacity(allocator, line_count) catch {
            self.cached_line_count = 0;
            self.cached_language = lang;
            self.cached_edit_counter = edit_counter;
            return;
        };

        var i: u32 = 0;
        while (i < line_count) : (i += 1) {
            self.entries.appendAssumeCapacity(.{});
        }

        self.cached_line_count = line_count;
        self.cached_language = lang;
        self.cached_edit_counter = edit_counter;
    }
};

pub const RenderState = struct {
    allocator: Allocator,
    cells: CellList,
    cursors: CursorList,
    selections: RectList,
    line_numbers: RectList,
    line_number_labels: LineNumberList,
    bracket_highlights: RectList,
    line_state_cache: LineStateCache = .{},
    line_token_cache: LineTokenCache = .{},
    scratch_line: std.ArrayListUnmanaged(u8) = .{},

    // Cached bracket match to avoid recomputing every frame
    cached_bracket_cursor_line: u32 = 0xFFFFFFFF,
    cached_bracket_cursor_col: u32 = 0xFFFFFFFF,
    cached_bracket_match: ?struct { line: u32, col: u32 } = null,
    bracket_cache_dirty: bool = true,
    last_edit_counter: u32 = 0xFFFFFFFF,

    pub fn init(allocator: Allocator) RenderState {
        return .{
            .allocator = allocator,
            .cells = .{},
            .cursors = .{},
            .selections = .{},
            .line_numbers = .{},
            .line_number_labels = .{},
            .bracket_highlights = .{},
        };
    }

    pub fn deinit(self: *RenderState) void {
        self.cells.deinit(self.allocator);
        self.cursors.deinit(self.allocator);
        self.selections.deinit(self.allocator);
        self.line_numbers.deinit(self.allocator);
        self.line_number_labels.deinit(self.allocator);
        self.bracket_highlights.deinit(self.allocator);
        self.line_state_cache.deinit(self.allocator);
        self.line_token_cache.deinit(self.allocator);
        self.scratch_line.deinit(self.allocator);
    }

    /// Compute render data for the visible viewport.
    pub fn compute(self: *RenderState, editor: anytype) void {
        const line_count = editor.buffer.lineCount();

        // Invalidate caches if buffer was edited
        if (self.last_edit_counter != editor.edit_counter) {
            self.last_edit_counter = editor.edit_counter;
            self.line_state_cache.invalidate();
            self.bracket_cache_dirty = true;
        }

        self.cells.clearRetainingCapacity();
        self.cursors.clearRetainingCapacity();
        self.selections.clearRetainingCapacity();
        self.line_numbers.clearRetainingCapacity();
        self.line_number_labels.clearRetainingCapacity();
        self.bracket_highlights.clearRetainingCapacity();

        const cell_w = editor.cell_width;
        const cell_h = if (editor.cell_height > 0) editor.cell_height else 16.0;
        const vp_w: f32 = @floatFromInt(editor.viewport_width);
        const vp_h: f32 = @floatFromInt(editor.viewport_height);
        const gutter_w = editor.gutterWidth();

        const config = editor.config;
        const lang = editor.language;
        const highlight = lang != .none;
        const wrap_enabled = config.wrap_lines;
        const wrap_width = if (wrap_enabled) editor.wrapWidthPixels() else 0;

        if (highlight) {
            if (self.line_token_cache.cached_edit_counter != editor.edit_counter or
                self.line_token_cache.cached_language != lang or
                self.line_token_cache.cached_line_count != line_count)
            {
                self.line_token_cache.invalidate(self.allocator, line_count, lang, editor.edit_counter);
            }
        } else if (self.line_token_cache.cached_line_count != 0) {
            self.line_token_cache.invalidate(self.allocator, 0, .none, editor.edit_counter);
        }

        // Track max line length for horizontal scroll clamping
        var max_line_len: u32 = 0;
        var max_line_width: f32 = 0;

        // Selection range
        const sel_active = editor.selection.active;
        var sel_start_line: u32 = 0;
        var sel_start_col: u32 = 0;
        var sel_end_line: u32 = 0;
        var sel_end_col: u32 = 0;
        if (sel_active) {
            const r = editor.selection.orderedRange(editor.cursor.line, editor.cursor.col);
            sel_start_line = r.start_line;
            sel_start_col = r.start_col;
            sel_end_line = r.end_line;
            sel_end_col = r.end_col;
        }

        // Find first visible buffer line
        const first_vrow: u32 = @intFromFloat(@max(0, editor.scroll_y / cell_h));
        const visible_vrows: u32 = @as(u32, @intFromFloat(vp_h / cell_h)) + 2;

        var scan_vrow: u32 = 0;
        var first_line: u32 = 0;
        if (wrap_enabled) {
            while (first_line < line_count) {
                const vrows = editor.lineVisualRows(first_line);
                if (scan_vrow + vrows > first_vrow) break;
                scan_vrow += vrows;
                first_line += 1;
            }
        } else {
            first_line = @min(first_vrow, line_count -| 1);
            scan_vrow = first_line;
        }

        // Compute multi-line state up to first visible line (using cache)
        var line_state = Lexer.LineState{};
        if (highlight and first_line > 0) {
            if (self.line_state_cache.dirty) {
                self.rebuildLineStateCache(editor, lang);
            }
            const nearest = self.line_state_cache.getNearest(first_line);
            line_state = nearest.state;
            var scan_line = nearest.from_line;
            while (scan_line < first_line) : (scan_line += 1) {
                line_state = self.lineEndState(editor, scan_line, line_state, lang) catch break;
            }
        }

        // Cursor visual row (precompute)
        var cursor_base_vrow: u32 = undefined;
        if (wrap_enabled) {
            cursor_base_vrow = editor.lineToVisualRow(editor.cursor.line);
        } else {
            cursor_base_vrow = editor.cursor.line;
        }

        // Generate cells for each visible line
        var current_vrow = scan_vrow;
        var line: u32 = first_line;
        while (line < line_count and current_vrow < first_vrow + visible_vrows) : (line += 1) {
            // Tokenize first (may populate scratch_line internally)
            var tokens: ?[]const Lexer.Token = null;
            if (highlight) {
                const entry = self.lineTokens(editor, line, line_state, lang) catch null;
                if (entry) |cached| {
                    tokens = cached.tokens;
                    line_state = cached.end_state;
                }
            }

            // Copy line content into scratch buffer for direct iteration
            const line_data = self.lineBytes(editor, line) catch {
                current_vrow += 1;
                continue;
            };
            const content_len: u32 = @intCast(line_data.len);

            var token_idx: u32 = 0;

            // Iterate characters with UTF-8 and wrapping
            var col: u32 = 0; // byte offset within line
            var vcol: u32 = 0; // visual column (grid units, CJK = 2)
            var seg_x_offset: f32 = 0; // point offset within current wrap segment
            var last_seg: u32 = 0;
            // Render line number on first visual row
            const line_base_vrow = current_vrow;
            if (config.line_numbers) {
                const y0 = @as(f32, @floatFromInt(line_base_vrow)) * cell_h - editor.scroll_y;
                if (y0 + cell_h >= 0 and y0 <= vp_h) {
                    self.line_numbers.append(self.allocator, .{
                        .x = 0,
                        .y = y0,
                        .w = gutter_w,
                        .h = cell_h,
                        .color = config.gutter_bg_color,
                    }) catch {};
                    self.line_number_labels.append(self.allocator, .{
                        .x = 0,
                        .y = y0,
                        .w = gutter_w,
                        .h = cell_h,
                        .color = config.line_number_color,
                        .line = line + 1,
                    }) catch {};
                }
            }

            while (col < content_len) {
                if (wrap_enabled and seg_x_offset >= wrap_width and seg_x_offset > 0) {
                    last_seg += 1;
                    seg_x_offset = 0;
                }

                const byte = line_data[col];
                if (byte == '\n') break;

                const cp_len = PieceTable.codepointByteLen(byte);
                const codepoint = decodeCodepointFromSlice(line_data, col);
                const cw: u32 = charWidth(codepoint);
                const char_px_w = editor.pixelWidthForCodepoint(codepoint);

                // Compute visual position
                const seg = last_seg;
                const vrow = line_base_vrow + seg;

                const y = @as(f32, @floatFromInt(vrow)) * cell_h - editor.scroll_y;
                const x = if (wrap_enabled)
                    seg_x_offset + gutter_w
                else
                    seg_x_offset - editor.scroll_x + gutter_w;

                if (y + cell_h >= 0 and y <= vp_h and x + char_px_w >= 0 and x <= vp_w) {
                    var bg_color = config.bg_color;

                    // Selection highlight
                    if (sel_active) {
                        if (isInSelection(line, col, sel_start_line, sel_start_col, sel_end_line, sel_end_col)) {
                            bg_color = config.selection_color;
                        }
                    }

                    // Determine foreground color from syntax tokens
                    var fg_color = config.fg_color;
                    if (tokens) |toks| {
                        while (token_idx < toks.len and
                            toks[token_idx].start + toks[token_idx].len <= col)
                        {
                            token_idx += 1;
                        }
                        if (token_idx < toks.len) {
                            const tok = toks[token_idx];
                            if (col >= tok.start and col < tok.start + tok.len) {
                                fg_color = config.theme.colorFor(tok.type);
                            }
                        }
                    }

                    self.cells.append(self.allocator, .{
                        .x = x,
                        .y = y,
                        .w = char_px_w,
                        .h = cell_h,
                        .fg = fg_color,
                        .bg = bg_color,
                        .glyph_index = codepoint,
                        .style = 0,
                    }) catch {};
                }

                col += cp_len;
                vcol += cw;
                seg_x_offset += char_px_w;
            }

            // Track the full line width, not just currently visible cells.
            if (vcol > max_line_len) max_line_len = vcol;
            if (seg_x_offset > max_line_width) max_line_width = seg_x_offset;

            // Visual rows this line occupies
            const line_vrows: u32 = if (wrap_enabled) last_seg + 1 else 1;

            // If line has no visible chars but is selected, add a selection rect
            if (sel_active and vcol == 0) {
                if (line >= sel_start_line and line <= sel_end_line) {
                    const y = @as(f32, @floatFromInt(line_base_vrow)) * cell_h - editor.scroll_y;
                    self.selections.append(self.allocator, .{
                        .x = gutter_w,
                        .y = y,
                        .w = cell_w,
                        .h = cell_h,
                        .color = config.selection_color,
                    }) catch {};
                }
            }

            // Render line number background for continuation rows (wrapped)
            if (wrap_enabled and config.line_numbers and line_vrows > 1) {
                var seg: u32 = 1;
                while (seg < line_vrows) : (seg += 1) {
                    const y = @as(f32, @floatFromInt(line_base_vrow + seg)) * cell_h - editor.scroll_y;
                    if (y + cell_h >= 0 and y <= vp_h) {
                        self.line_numbers.append(self.allocator, .{
                            .x = 0,
                            .y = y,
                            .w = gutter_w,
                            .h = cell_h,
                            .color = config.gutter_bg_color,
                        }) catch {};
                    }
                }
            }

            current_vrow += line_vrows;
        }

        // Store max visible line length for horizontal scroll clamping
        editor.max_visible_line_len = max_line_len;
        editor.max_visible_line_width = max_line_width;

        // Current line highlight
        {
            const hl_y = @as(f32, @floatFromInt(cursor_base_vrow)) * cell_h - editor.scroll_y;
            if (hl_y + cell_h >= 0 and hl_y <= vp_h) {
                self.selections.append(self.allocator, .{
                    .x = gutter_w,
                    .y = hl_y,
                    .w = vp_w - gutter_w,
                    .h = cell_h,
                    .color = config.current_line_color,
                }) catch {};
            }
        }

        // Cursor
        const cursor_metrics = editor.byteColToPixelMetrics(editor.cursor.line, editor.cursor.col);
        const cursor_x = (if (wrap_enabled) cursor_metrics.segment_x else cursor_metrics.total_x) + gutter_w -
            if (!wrap_enabled) editor.scroll_x else @as(f32, 0);
        const cursor_y = @as(f32, @floatFromInt(cursor_base_vrow + cursor_metrics.segment)) * cell_h - editor.scroll_y;

        self.cursors.append(self.allocator, .{
            .x = cursor_x,
            .y = cursor_y,
            .w = 2, // beam cursor width
            .h = cell_h,
            .color = config.cursor_color,
            .style = 1, // beam
        }) catch {};

        // Bracket matching highlights (cached — only recompute when cursor moves or buffer changes)
        if (self.bracket_cache_dirty or
            self.cached_bracket_cursor_line != editor.cursor.line or
            self.cached_bracket_cursor_col != editor.cursor.col)
        {
            self.cached_bracket_cursor_line = editor.cursor.line;
            self.cached_bracket_cursor_col = editor.cursor.col;
            self.cached_bracket_match = if (editor.findMatchingBracket()) |m| .{ .line = m.line, .col = m.col } else null;
            self.bracket_cache_dirty = false;
        }
        if (self.cached_bracket_match) |match| {
            const bracket_color: u32 = 0x585B7080; // subtle highlight
            // Highlight the matching bracket
            const match_metrics = editor.byteColToPixelMetrics(match.line, match.col);
            const m_base_vrow = if (wrap_enabled) editor.lineToVisualRow(match.line) else match.line;
            const mx = (if (wrap_enabled) match_metrics.segment_x else match_metrics.total_x) + gutter_w -
                if (!wrap_enabled) editor.scroll_x else @as(f32, 0);
            const my = @as(f32, @floatFromInt(m_base_vrow + match_metrics.segment)) * cell_h - editor.scroll_y;
            self.bracket_highlights.append(self.allocator, .{
                .x = mx,
                .y = my,
                .w = cell_w,
                .h = cell_h,
                .color = bracket_color,
            }) catch {};
            // Highlight the bracket at cursor
            self.bracket_highlights.append(self.allocator, .{
                .x = cursor_x,
                .y = cursor_y,
                .w = cell_w,
                .h = cell_h,
                .color = bracket_color,
            }) catch {};
        }
    }

    fn rebuildLineStateCache(self: *RenderState, editor: anytype, lang: Language) void {
        const total_lines = editor.buffer.lineCount();
        const interval = self.line_state_cache.interval;
        const num_entries = (total_lines + interval - 1) / interval;

        self.line_state_cache.states.clearRetainingCapacity();
        self.line_state_cache.states.ensureTotalCapacity(self.allocator, num_entries) catch return;

        var state = Lexer.LineState{};
        // Entry 0: state at line 0 (always default)
        self.line_state_cache.states.append(self.allocator, state) catch return;

        var line: u32 = 0;
        while (line < total_lines) : (line += 1) {
            state = self.lineEndState(editor, line, state, lang) catch break;

            // Save checkpoint at interval boundaries
            if ((line + 1) % interval == 0) {
                self.line_state_cache.states.append(self.allocator, state) catch break;
            }
        }

        self.line_state_cache.cached_line_count = total_lines;
        self.line_state_cache.dirty = false;
    }

    fn lineTokens(
        self: *RenderState,
        editor: anytype,
        line: u32,
        line_state: Lexer.LineState,
        lang: Language,
    ) !*const LineTokenCacheEntry {
        const idx: usize = @intCast(line);
        const entry = &self.line_token_cache.entries.items[idx];
        if (!entry.valid) {
            const line_bytes = try self.lineBytes(editor, line);
            const result = try Lexer.tokenizeLine(self.allocator, line_bytes, line_state, lang);
            entry.tokens = result.tokens;
            entry.end_state = result.end_state;
            entry.valid = true;
        }
        return entry;
    }

    fn lineEndState(self: *RenderState, editor: anytype, line: u32, line_state: Lexer.LineState, lang: Language) !Lexer.LineState {
        const idx: usize = @intCast(line);
        if (self.line_token_cache.entries.items.len > idx) {
            const entry = &self.line_token_cache.entries.items[idx];
            if (entry.valid) return entry.end_state;
        }

        const line_bytes = try self.lineBytes(editor, line);
        return Lexer.scanLineState(line_bytes, line_state, lang);
    }

    fn lineBytes(self: *RenderState, editor: anytype, line: u32) ![]const u8 {
        const start = editor.buffer.lineStart(line);
        const end = editor.buffer.lineEnd(line);
        const len = end - start;
        try self.scratch_line.resize(self.allocator, len);
        if (len == 0) return self.scratch_line.items;
        editor.buffer.copyRange(start, end, self.scratch_line.items);
        return self.scratch_line.items;
    }

    fn isInSelection(line: u32, col: u32, start_line: u32, start_col: u32, end_line: u32, end_col: u32) bool {
        if (line < start_line or line > end_line) return false;
        if (line == start_line and col < start_col) return false;
        if (line == end_line and col >= end_col) return false;
        return true;
    }
};

fn decodeCodepointFromSlice(data: []const u8, pos: u32) u32 {
    const p: usize = pos;
    if (p >= data.len) return 0xFFFD;
    const b0 = data[p];
    if (b0 < 0x80) return b0;
    if (b0 < 0xC0) return 0xFFFD;
    if (b0 < 0xE0) {
        if (p + 1 >= data.len) return 0xFFFD;
        return (@as(u32, b0 & 0x1F) << 6) | @as(u32, data[p + 1] & 0x3F);
    }
    if (b0 < 0xF0) {
        if (p + 2 >= data.len) return 0xFFFD;
        return (@as(u32, b0 & 0x0F) << 12) | (@as(u32, data[p + 1] & 0x3F) << 6) | @as(u32, data[p + 2] & 0x3F);
    }
    if (p + 3 >= data.len) return 0xFFFD;
    return (@as(u32, b0 & 0x07) << 18) | (@as(u32, data[p + 1] & 0x3F) << 12) | (@as(u32, data[p + 2] & 0x3F) << 6) | @as(u32, data[p + 3] & 0x3F);
}

const testing = std.testing;
const Config = @import("../config/Config.zig").Config;
const Editor = @import("../editor/Editor.zig").Editor;

test "RenderState: wrapped gutter rows only emit one line number label" {
    var config = Config.defaults();
    config.wrap_lines = true;
    config.line_numbers = true;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.setViewport(8, 10, 1, 1);
    try ed.insertText("abcdefghi");

    ed.prepareRender();

    try testing.expectEqual(@as(usize, 3), ed.render_state.line_numbers.items.len);
    try testing.expectEqual(@as(usize, 1), ed.render_state.line_number_labels.items.len);
    try testing.expectEqual(@as(u32, 1), ed.render_state.line_number_labels.items[0].line);
}

test "RenderState: highlight tokens are reused across redraws without edits" {
    var config = Config.defaults();

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.language = .zig;
    ed.setViewport(80, 10, 1, 1);
    try ed.insertText("const answer = 42;");

    ed.prepareRender();

    const first_tokens = ed.render_state.line_token_cache.entries.items[0].tokens;
    try testing.expect(first_tokens.len > 0);

    ed.moveLeft();
    ed.prepareRender();

    const second_tokens = ed.render_state.line_token_cache.entries.items[0].tokens;
    try testing.expectEqual(first_tokens.ptr, second_tokens.ptr);
    try testing.expectEqual(first_tokens.len, second_tokens.len);
}

test "RenderState: fullwidth cells stay aligned with the cursor grid" {
    var config = Config.defaults();
    config.line_numbers = false;
    config.wrap_lines = false;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.setViewport(80, 20, 1, 1);
    ed.setWideCellWidth(1.5);
    try ed.insertText("a好b");
    ed.cursor.moveTo(0, 4);

    ed.prepareRender();

    try testing.expectEqual(@as(usize, 3), ed.render_state.cells.items.len);
    try testing.expectEqual(@as(f32, 0), ed.render_state.cells.items[0].x);
    try testing.expectEqual(@as(f32, 1), ed.render_state.cells.items[1].x);
    try testing.expectEqual(@as(f32, 1.5), ed.render_state.cells.items[1].w);
    try testing.expectEqual(@as(f32, 2.5), ed.render_state.cells.items[2].x);
    try testing.expectEqual(@as(f32, 2.5), ed.render_state.cursors.items[0].x);
}

test "RenderState: Hangul uses its measured width instead of Han width" {
    var config = Config.defaults();
    config.line_numbers = false;
    config.wrap_lines = false;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.setViewport(80, 20, 1, 1);
    ed.setWideCellWidth(1.5);
    ed.setHangulCellWidth(1.25);
    try ed.insertText("a한b");
    ed.cursor.moveTo(0, 4);

    ed.prepareRender();

    try testing.expectEqual(@as(usize, 3), ed.render_state.cells.items.len);
    try testing.expectEqual(@as(f32, 1.25), ed.render_state.cells.items[1].w);
    try testing.expectEqual(@as(f32, 2.25), ed.render_state.cells.items[2].x);
    try testing.expectEqual(@as(f32, 2.25), ed.render_state.cursors.items[0].x);
}

test "RenderState: exact-fit wrapped CJK does not create a phantom row" {
    var config = Config.defaults();
    config.line_numbers = false;
    config.wrap_lines = true;

    var ed = Editor.init(testing.allocator, &config);
    defer ed.deinit();

    ed.setViewport(4, 10, 1, 1);
    ed.setWideCellWidth(1.5);
    try ed.insertText("a好好");
    ed.cursor.moveTo(0, 7);

    ed.prepareRender();

    try testing.expectEqual(@as(u32, 1), ed.lineVisualRows(0));
    try testing.expectEqual(@as(usize, 3), ed.render_state.cells.items.len);
    try testing.expectEqual(@as(f32, 0), ed.render_state.cells.items[0].y);
    try testing.expectEqual(@as(f32, 0), ed.render_state.cells.items[1].y);
    try testing.expectEqual(@as(f32, 0), ed.render_state.cells.items[2].y);
    try testing.expectEqual(@as(f32, 4), ed.render_state.cursors.items[0].x);
    try testing.expectEqual(@as(f32, 0), ed.render_state.cursors.items[0].y);
}
