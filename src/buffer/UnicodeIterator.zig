/// Returns the display width of a Unicode codepoint.
/// CJK ideographs and fullwidth forms return 2; everything else returns 1.
pub fn charWidth(cp: u32) u2 {
    // Fast path: ASCII and Latin
    if (cp < 0x1100) return 1;

    // Hangul Jamo
    if (cp <= 0x115F) return 2;
    if (cp < 0x2E80) return 1;

    // CJK Radicals, Kangxi, CJK Symbols, Hiragana, Katakana, Bopomofo, etc.
    if (cp <= 0x303E) return 2;
    if (cp < 0x3040) return 1;
    // Hiragana through CJK Strokes, CJK Extension A, CJK Unified, Yi, Hangul
    if (cp <= 0xA4CF) return 2;
    if (cp < 0xAC00) return 1;
    // Hangul Syllables
    if (cp <= 0xD7AF) return 2;
    if (cp < 0xF900) return 1;
    // CJK Compatibility Ideographs
    if (cp <= 0xFAFF) return 2;
    if (cp < 0xFE10) return 1;
    // Vertical forms, CJK Compat Forms, Small Form Variants
    if (cp <= 0xFE6F) return 2;
    if (cp < 0xFF01) return 1;
    // Fullwidth ASCII variants
    if (cp <= 0xFF60) return 2;
    if (cp < 0xFFE0) return 1;
    // Fullwidth signs
    if (cp <= 0xFFE6) return 2;
    if (cp < 0x1F300) return 1;
    // Emoji: Miscellaneous Symbols, Dingbats, Emoticons, Transport, etc.
    if (cp <= 0x1F9FF) return 2;
    if (cp < 0x20000) return 1;
    // CJK Unified Ideographs Extension B through G and beyond
    if (cp <= 0x3FFFD) return 2;

    return 1;
}

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
