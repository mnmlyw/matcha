/// UTF-8 aware iteration over byte sequences.
/// For v0.1, we treat bytes as ASCII/UTF-8 code units.
/// Full grapheme cluster support is deferred.
pub const UnicodeIterator = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) UnicodeIterator {
        return .{ .data = data };
    }

    /// Returns the next byte (for v0.1, byte-level iteration).
    pub fn next(self: *UnicodeIterator) ?u8 {
        if (self.pos >= self.data.len) return null;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    /// Returns the next codepoint and advances past it.
    pub fn nextCodepoint(self: *UnicodeIterator) ?u32 {
        if (self.pos >= self.data.len) return null;
        const b0 = self.data[self.pos];
        if (b0 < 0x80) {
            self.pos += 1;
            return b0;
        } else if (b0 < 0xC0) {
            // Continuation byte — skip
            self.pos += 1;
            return 0xFFFD; // replacement char
        } else if (b0 < 0xE0) {
            if (self.pos + 1 >= self.data.len) { self.pos += 1; return 0xFFFD; }
            const cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, self.data[self.pos + 1] & 0x3F);
            self.pos += 2;
            return cp;
        } else if (b0 < 0xF0) {
            if (self.pos + 2 >= self.data.len) { self.pos += 1; return 0xFFFD; }
            const cp = (@as(u32, b0 & 0x0F) << 12) |
                (@as(u32, self.data[self.pos + 1] & 0x3F) << 6) |
                @as(u32, self.data[self.pos + 2] & 0x3F);
            self.pos += 3;
            return cp;
        } else {
            if (self.pos + 3 >= self.data.len) { self.pos += 1; return 0xFFFD; }
            const cp = (@as(u32, b0 & 0x07) << 18) |
                (@as(u32, self.data[self.pos + 1] & 0x3F) << 12) |
                (@as(u32, self.data[self.pos + 2] & 0x3F) << 6) |
                @as(u32, self.data[self.pos + 3] & 0x3F);
            self.pos += 4;
            return cp;
        }
    }
};
