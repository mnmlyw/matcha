/// Single cursor position (0-based line and column).
pub const Cursor = struct {
    line: u32 = 0,
    col: u32 = 0,
    /// Desired column for vertical movement (sticky column).
    target_col: u32 = 0,

    pub fn moveTo(self: *Cursor, line: u32, col: u32) void {
        self.line = line;
        self.col = col;
        self.target_col = col;
    }

    pub fn moveToKeepTarget(self: *Cursor, line: u32, col: u32) void {
        self.line = line;
        self.col = col;
    }
};
