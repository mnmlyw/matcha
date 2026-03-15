const std = @import("std");
const Allocator = std.mem.Allocator;
const Cell = @import("Cell.zig");
const Lexer = @import("../highlight/Lexer.zig");
const TokenType = @import("../highlight/TokenType.zig").TokenType;
const Theme = @import("../highlight/TokenType.zig").Theme;
const Language = @import("../highlight/Language.zig").Language;

const CellList = std.ArrayListUnmanaged(Cell.RenderCell);
const CursorList = std.ArrayListUnmanaged(Cell.RenderCursor);
const RectList = std.ArrayListUnmanaged(Cell.RenderRect);

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
            .bracket_highlights = .{},
        };
    }

    pub fn deinit(self: *RenderState) void {
        self.cells.deinit(self.allocator);
        self.cursors.deinit(self.allocator);
        self.selections.deinit(self.allocator);
        self.line_numbers.deinit(self.allocator);
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
        self.bracket_highlights.clearRetainingCapacity();

        const cell_w = editor.cell_width;
        const cell_h = editor.cell_height;
        const vp_w: f32 = @floatFromInt(editor.viewport_width);
        const vp_h: f32 = @floatFromInt(editor.viewport_height);
        const gutter_w = editor.gutterWidth();

        // Determine visible line range
        const first_line: u32 = @intFromFloat(@max(0, editor.scroll_y / cell_h));
        const visible_lines: u32 = @intFromFloat(vp_h / cell_h);
        const last_line = @min(first_line + visible_lines + 2, editor.buffer.lineCount());

        const config = editor.config;
        const lang = editor.language;
        const highlight = lang != .none;

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

        // Compute multi-line state up to first visible line (using cache)
        var line_state = Lexer.LineState{};
        if (highlight and first_line > 0) {
            // Rebuild cache if dirty
            if (self.line_state_cache.dirty) {
                self.rebuildLineStateCache(editor, lang);
            }
            // Start from nearest cached checkpoint
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

        // Generate cells for each visible line
        var line: u32 = first_line;
        while (line < last_line) : (line += 1) {
            const y = @as(f32, @floatFromInt(line)) * cell_h - editor.scroll_y;

            // Line number gutter
            if (config.line_numbers) {
                self.line_numbers.append(self.allocator, .{
                    .x = 0,
                    .y = y,
                    .w = gutter_w,
                    .h = cell_h,
                    .color = config.gutter_bg_color,
                }) catch {};
            }

            // Get line content
            const line_start = editor.buffer.lineStart(line);
            const line_end = editor.buffer.lineEnd(line);
            const line_len = line_end - line_start;

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
            var rendered_chars: u32 = 0;

            var col: u32 = 0;
            while (col < line_len) : (col += 1) {
                const byte = editor.buffer.byteAt(line_start + col) orelse break;
                if (byte == '\n') break;

                const x = @as(f32, @floatFromInt(col)) * cell_w - editor.scroll_x + gutter_w;

                // Skip offscreen cells
                if (x + cell_w < 0 or x > vp_w) continue;

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
                    // Advance token index to cover current column
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
                    .glyph_index = @as(u32, byte),
                    .style = 0,
                }) catch {};
                rendered_chars += 1;
            }

            // Track longest visible line for scroll clamping
            if (rendered_chars > max_line_len) max_line_len = rendered_chars;

            // If line has no visible chars but is selected, add a selection rect
            if (sel_active and rendered_chars == 0) {
                if (line >= sel_start_line and line <= sel_end_line) {
                    self.selections.append(self.allocator, .{
                        .x = gutter_w,
                        .y = y,
                        .w = cell_w,
                        .h = cell_h,
                        .color = config.selection_color,
                    }) catch {};
                }
            }
        }

        // Store max visible line length for horizontal scroll clamping
        editor.max_visible_line_len = max_line_len;

        // Cursor
        const cursor_x = @as(f32, @floatFromInt(editor.cursor.col)) * cell_w - editor.scroll_x + gutter_w;
        const cursor_y = @as(f32, @floatFromInt(editor.cursor.line)) * cell_h - editor.scroll_y;

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
            const mx = @as(f32, @floatFromInt(match.col)) * cell_w - editor.scroll_x + gutter_w;
            const my = @as(f32, @floatFromInt(match.line)) * cell_h - editor.scroll_y;
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
