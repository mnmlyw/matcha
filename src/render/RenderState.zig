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

pub const RenderState = struct {
    allocator: Allocator,
    cells: CellList,
    cursors: CursorList,
    selections: RectList,
    line_numbers: RectList,

    pub fn init(allocator: Allocator) RenderState {
        return .{
            .allocator = allocator,
            .cells = .{},
            .cursors = .{},
            .selections = .{},
            .line_numbers = .{},
        };
    }

    pub fn deinit(self: *RenderState) void {
        self.cells.deinit(self.allocator);
        self.cursors.deinit(self.allocator);
        self.selections.deinit(self.allocator);
        self.line_numbers.deinit(self.allocator);
    }

    /// Compute render data for the visible viewport.
    pub fn compute(self: *RenderState, editor: anytype) void {
        self.cells.clearRetainingCapacity();
        self.cursors.clearRetainingCapacity();
        self.selections.clearRetainingCapacity();
        self.line_numbers.clearRetainingCapacity();

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

        // Compute multi-line state up to first visible line
        var line_state = Lexer.LineState{};
        if (highlight and first_line > 0) {
            var scan_line: u32 = 0;
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
            }

            // If line is empty but selected, add an empty selection rect
            if (sel_active and line_len == 0) {
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
