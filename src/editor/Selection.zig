/// A selection range defined by anchor and cursor positions.
pub const Selection = struct {
    active: bool = false,
    /// Anchor: where the selection started (byte offset).
    anchor_line: u32 = 0,
    anchor_col: u32 = 0,

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    pub fn setAnchor(self: *Selection, line: u32, col: u32) void {
        self.active = true;
        self.anchor_line = line;
        self.anchor_col = col;
    }

    /// Returns ordered start/end positions (line, col) for the selection,
    /// given the current cursor position.
    pub fn orderedRange(self: *const Selection, cursor_line: u32, cursor_col: u32) struct {
        start_line: u32,
        start_col: u32,
        end_line: u32,
        end_col: u32,
    } {
        if (!self.active) return .{
            .start_line = cursor_line,
            .start_col = cursor_col,
            .end_line = cursor_line,
            .end_col = cursor_col,
        };

        const anchor_before = self.anchor_line < cursor_line or
            (self.anchor_line == cursor_line and self.anchor_col <= cursor_col);

        if (anchor_before) {
            return .{
                .start_line = self.anchor_line,
                .start_col = self.anchor_col,
                .end_line = cursor_line,
                .end_col = cursor_col,
            };
        } else {
            return .{
                .start_line = cursor_line,
                .start_col = cursor_col,
                .end_line = self.anchor_line,
                .end_col = self.anchor_col,
            };
        }
    }
};
