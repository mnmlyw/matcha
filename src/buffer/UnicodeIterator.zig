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

/// Returns the byte length of the grapheme cluster starting at `pos` in `data`.
/// Handles combining marks, regional indicators (flags), ZWJ sequences,
/// variation selectors, skin tone modifiers, and combining keycap.
pub fn nextClusterLen(data: []const u8, pos: u32) u32 {
    const p: usize = pos;
    if (p >= data.len) return 0;

    const first_cp = decodeCpAt(data, p);
    const first_byte_len = cpByteLenAt(data, p);
    var end: usize = p + first_byte_len;

    // Regional indicators: consume exactly two
    if (first_cp >= 0x1F1E6 and first_cp <= 0x1F1FF) {
        if (end < data.len) {
            const next_cp = decodeCpAt(data, end);
            if (next_cp >= 0x1F1E6 and next_cp <= 0x1F1FF) {
                end += cpByteLenAt(data, end);
            }
        }
        return @intCast(end - p);
    }

    // Extend cluster with combining/modifier codepoints
    while (end < data.len) {
        const next_cp = decodeCpAt(data, end);
        const next_len = cpByteLenAt(data, end);

        if (isExtender(next_cp)) {
            // Combining marks, variation selectors, keycap, skin modifiers
            end += next_len;
        } else if (next_cp == 0x200D) {
            // ZWJ: consume ZWJ + next codepoint (if available)
            const after_zwj = end + next_len;
            if (after_zwj >= data.len) break; // ZWJ at end of string, stop
            end = after_zwj + cpByteLenAt(data, after_zwj);
            if (end > data.len) end = data.len; // clamp to buffer
        } else {
            break;
        }
    }
    return @intCast(end - p);
}

fn isExtender(cp: u32) bool {
    if (cp == 0xFE0F or cp == 0xFE0E) return true; // variation selectors
    if (cp == 0x20E3) return true; // combining enclosing keycap
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return true; // skin tone modifiers
    if (cp >= 0x0300 and cp <= 0x036F) return true; // combining diacritical marks
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return true;
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return true;
    if (cp >= 0x20D0 and cp <= 0x20FF) return true;
    if (cp >= 0xFE20 and cp <= 0xFE2F) return true;
    if (cp >= 0xE0020 and cp <= 0xE007F) return true; // tag sequences (flag subdivisions)
    if (cp == 0xE0001) return true; // language tag
    return false;
}

fn decodeCpAt(data: []const u8, pos: usize) u32 {
    if (pos >= data.len) return 0xFFFD;
    const b0 = data[pos];
    if (b0 < 0x80) return b0;
    if (b0 < 0xC0) return 0xFFFD;
    if (b0 < 0xE0) {
        if (pos + 1 >= data.len) return 0xFFFD;
        return (@as(u32, b0 & 0x1F) << 6) | @as(u32, data[pos + 1] & 0x3F);
    }
    if (b0 < 0xF0) {
        if (pos + 2 >= data.len) return 0xFFFD;
        return (@as(u32, b0 & 0x0F) << 12) | (@as(u32, data[pos + 1] & 0x3F) << 6) | @as(u32, data[pos + 2] & 0x3F);
    }
    if (pos + 3 >= data.len) return 0xFFFD;
    return (@as(u32, b0 & 0x07) << 18) | (@as(u32, data[pos + 1] & 0x3F) << 12) | (@as(u32, data[pos + 2] & 0x3F) << 6) | @as(u32, data[pos + 3] & 0x3F);
}

fn cpByteLenAt(data: []const u8, pos: usize) usize {
    if (pos >= data.len) return 1;
    const b = data[pos];
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1;
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    return 4;
}

/// Sentinel value: glyph_index values >= this indicate a cluster string offset.
pub const CLUSTER_SENTINEL: u32 = 0x110000;

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
