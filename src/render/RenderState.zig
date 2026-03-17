const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("Cell.zig");
const Lexer = @import("../highlight/Lexer.zig");
const TokenType = @import("../highlight/TokenType.zig").TokenType;
const Theme = @import("../highlight/TokenType.zig").Theme;
const Language = @import("../highlight/Language.zig").Language;
const PieceTable = @import("../buffer/PieceTable.zig").PieceTable;

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

pub const RenderState = struct {
    allocator: Allocator,
    cells: CellList,
    cursors: CursorList,
    selections: RectList,
    line_numbers: RectList,
    line_number_labels: LineNumberList,
    bracket_highlights: RectList,
    line_state_cache: LineStateCache = .{},

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
    }

    /// Compute render data for the visible viewport.
    pub fn compute(self: *RenderState, editor: anytype) void {
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
        const wrap_col: u32 = if (wrap_enabled) editor.wrapCol() else std.math.maxInt(u32);

        // Track max line length for horizontal scroll clamping
        var max_line_len: u32 = 0;

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
        const line_count = editor.buffer.lineCount();

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
                const scan_content = getLineBytesAlloc(self.allocator, editor, scan_line) catch break;
                defer self.allocator.free(scan_content);
                const result = Lexer.tokenizeLine(self.allocator, scan_content, line_state, lang) catch break;
                line_state = result.end_state;
                self.allocator.free(result.tokens);
            }
        }

        // Cursor visual row (precompute)
        var cursor_base_vrow: u32 = undefined;
        if (wrap_enabled) {
            cursor_base_vrow = editor.lineToVisualRow(editor.cursor.line);
        } else {
            cursor_base_vrow = editor.cursor.line;
        }
        const cursor_vcol = editor.byteColToVisualCol(editor.cursor.line, editor.cursor.col);
        const cursor_seg: u32 = if (wrap_enabled and wrap_col > 0) cursor_vcol / wrap_col else 0;
        const cursor_seg_col: u32 = if (wrap_enabled and wrap_col > 0) cursor_vcol % wrap_col else cursor_vcol;
        const cursor_vrow_abs = cursor_base_vrow + cursor_seg;

        // Generate cells for each visible line
        var current_vrow = scan_vrow;
        var line: u32 = first_line;
        while (line < line_count and current_vrow < first_vrow + visible_vrows) : (line += 1) {
            // Get line content
            const line_start = editor.buffer.lineStart(line);
            const line_end = editor.buffer.lineEnd(line);
            var content_len = line_end - line_start;
            if (content_len > 0) {
                if (editor.buffer.byteAt(line_start + content_len - 1)) |b| {
                    if (b == '\n') content_len -= 1;
                }
            }

            // Tokenize line for highlighting
            var tokens: ?[]Lexer.Token = null;
            defer if (tokens) |t| self.allocator.free(t);

            if (highlight) {
                const line_content = getLineBytesAlloc(self.allocator, editor, line) catch null;
                defer if (line_content) |lc| self.allocator.free(lc);
                if (line_content) |lc| {
                    if (Lexer.tokenizeLine(self.allocator, lc, line_state, lang)) |result| {
                        tokens = result.tokens;
                        line_state = result.end_state;
                    } else |_| {}
                }
            }

            var token_idx: u32 = 0;

            // Iterate characters with UTF-8 and wrapping
            var col: u32 = 0; // byte offset within line
            var vcol: u32 = 0; // visual column (codepoint count)

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
                const byte = editor.buffer.byteAt(line_start + col) orelse break;
                if (byte == '\n') break;

                const cp_len = PieceTable.codepointByteLen(byte);
                const codepoint = editor.buffer.codepointAt(line_start + col);

                // Compute visual position
                const seg: u32 = if (wrap_enabled) vcol / wrap_col else 0;
                const seg_col: u32 = if (wrap_enabled) vcol % wrap_col else vcol;
                const vrow = line_base_vrow + seg;

                const y = @as(f32, @floatFromInt(vrow)) * cell_h - editor.scroll_y;
                const x = if (wrap_enabled)
                    @as(f32, @floatFromInt(seg_col)) * cell_w + gutter_w
                else
                    @as(f32, @floatFromInt(seg_col)) * cell_w - editor.scroll_x + gutter_w;

                if (y + cell_h >= 0 and y <= vp_h and x + cell_w >= 0 and x <= vp_w) {
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
                        .w = cell_w,
                        .h = cell_h,
                        .fg = fg_color,
                        .bg = bg_color,
                        .glyph_index = codepoint,
                        .style = 0,
                    }) catch {};
                }

                col += cp_len;
                vcol += 1;
            }

            // Track the full line width, not just currently visible cells.
            if (vcol > max_line_len) max_line_len = vcol;

            // Visual rows this line occupies
            const line_vrows: u32 = if (wrap_enabled) @max(1, if (vcol == 0) @as(u32, 1) else (vcol + wrap_col - 1) / wrap_col) else 1;

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

        // Cursor
        const cursor_x = @as(f32, @floatFromInt(cursor_seg_col)) * cell_w + gutter_w -
            if (!wrap_enabled) editor.scroll_x else @as(f32, 0);
        const cursor_y = @as(f32, @floatFromInt(cursor_vrow_abs)) * cell_h - editor.scroll_y;

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
            const m_vcol = editor.byteColToVisualCol(match.line, match.col);
            const m_base_vrow = if (wrap_enabled) editor.lineToVisualRow(match.line) else match.line;
            const m_seg: u32 = if (wrap_enabled and wrap_col > 0) m_vcol / wrap_col else 0;
            const m_seg_col: u32 = if (wrap_enabled and wrap_col > 0) m_vcol % wrap_col else m_vcol;
            const mx = @as(f32, @floatFromInt(m_seg_col)) * cell_w + gutter_w -
                if (!wrap_enabled) editor.scroll_x else @as(f32, 0);
            const my = @as(f32, @floatFromInt(m_base_vrow + m_seg)) * cell_h - editor.scroll_y;
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
            const content = getLineBytesAlloc(self.allocator, editor, line) catch break;
            defer self.allocator.free(content);
            const result = Lexer.tokenizeLine(self.allocator, content, state, lang) catch break;
            state = result.end_state;
            self.allocator.free(result.tokens);

            // Save checkpoint at interval boundaries
            if ((line + 1) % interval == 0) {
                self.line_state_cache.states.append(self.allocator, state) catch break;
            }
        }

        self.line_state_cache.cached_line_count = total_lines;
        self.line_state_cache.dirty = false;
    }

    fn getLineBytesAlloc(allocator: Allocator, editor: anytype, line: u32) ![]u8 {
        const start = editor.buffer.lineStart(line);
        const end = editor.buffer.lineEnd(line);
        if (end <= start) return try allocator.alloc(u8, 0);
        // Strip trailing newline for tokenization
        var actual_end = end;
        if (editor.buffer.byteAt(actual_end - 1)) |b| {
            if (b == '\n') actual_end -= 1;
        }
        if (actual_end <= start) return try allocator.alloc(u8, 0);
        return editor.buffer.getRange(allocator, start, actual_end);
    }

    fn isInSelection(line: u32, col: u32, start_line: u32, start_col: u32, end_line: u32, end_col: u32) bool {
        if (line < start_line or line > end_line) return false;
        if (line == start_line and col < start_col) return false;
        if (line == end_line and col >= end_col) return false;
        return true;
    }
};

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
