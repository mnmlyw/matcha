const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Source = enum(u1) {
    original = 0,
    add = 1,
};

pub const Piece = struct {
    source: Source,
    start: u32,
    length: u32,
};

const PieceList = std.ArrayListUnmanaged(Piece);
const ByteBuffer = std.ArrayListUnmanaged(u8);

pub const PieceTable = struct {
    allocator: Allocator,
    original: []const u8,
    original_owned: bool,
    add_buffer: ByteBuffer,
    pieces: PieceList,
    cached_line_count: ?u32 = null,
    cached_total_length: ?u32 = null,

    pub fn init(allocator: Allocator) PieceTable {
        return .{
            .allocator = allocator,
            .original = &.{},
            .original_owned = false,
            .add_buffer = .{},
            .pieces = .{},
        };
    }

    pub fn initWithContent(allocator: Allocator, content: []const u8) !PieceTable {
        var pt = init(allocator);
        if (content.len > 0) {
            const owned = try allocator.dupe(u8, content);
            pt.original = owned;
            pt.original_owned = true;
            try pt.pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .length = @intCast(content.len),
            });
        }
        pt.refreshCaches();
        return pt;
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.original_owned) {
            self.allocator.free(self.original);
        }
        self.add_buffer.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
    }

    /// Total length of the document in bytes (cached).
    pub fn totalLength(self: *const PieceTable) u32 {
        if (self.cached_total_length) |c| return c;
        var len: u32 = 0;
        for (self.pieces.items) |p| {
            len += p.length;
        }
        return len;
    }

    /// Insert `text` at byte offset `pos`.
    pub fn insert(self: *PieceTable, pos: u32, text: []const u8) !void {
        if (text.len == 0) return;

        const add_start: u32 = @intCast(self.add_buffer.items.len);
        try self.add_buffer.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .length = @intCast(text.len),
        };

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, new_piece);
            self.refreshCaches();
            return;
        }

        // Find which piece contains `pos`
        var offset: u32 = 0;
        var idx: usize = 0;
        while (idx < self.pieces.items.len) : (idx += 1) {
            const p = self.pieces.items[idx];
            if (pos <= offset + p.length) break;
            offset += p.length;
        }

        if (idx >= self.pieces.items.len) {
            // Append at end
            try self.pieces.append(self.allocator, new_piece);
            self.refreshCaches();
            return;
        }

        const p = self.pieces.items[idx];
        const rel = pos - offset;

        if (rel == 0) {
            // Insert before this piece
            try self.pieces.insert(self.allocator, idx, new_piece);
        } else if (rel == p.length) {
            // Insert after this piece
            try self.pieces.insert(self.allocator, idx + 1, new_piece);
        } else {
            // Split the piece
            const left = Piece{
                .source = p.source,
                .start = p.start,
                .length = rel,
            };
            const right = Piece{
                .source = p.source,
                .start = p.start + rel,
                .length = p.length - rel,
            };
            // Replace current with left, insert new_piece and right
            self.pieces.items[idx] = left;
            try self.pieces.insert(self.allocator, idx + 1, new_piece);
            try self.pieces.insert(self.allocator, idx + 2, right);
        }
        self.refreshCaches();
    }

    /// Delete `len` bytes starting at byte offset `pos`.
    pub fn delete(self: *PieceTable, pos: u32, len: u32) !void {
        if (len == 0) return;

        var remaining = len;
        const current_pos = pos;
        _ = current_pos;

        while (remaining > 0) {
            var offset: u32 = 0;
            var idx: usize = 0;
            // Always search from `pos` since earlier pieces may have been removed/shrunk
            while (idx < self.pieces.items.len) : (idx += 1) {
                const p = self.pieces.items[idx];
                if (pos < offset + p.length) break;
                offset += p.length;
            }

            if (idx >= self.pieces.items.len) break;

            const p = self.pieces.items[idx];
            const rel = pos - offset;
            const avail = p.length - rel;
            const to_delete = @min(remaining, avail);

            if (rel == 0 and to_delete == p.length) {
                // Remove entire piece
                _ = self.pieces.orderedRemove(idx);
            } else if (rel == 0) {
                // Trim from start
                self.pieces.items[idx] = Piece{
                    .source = p.source,
                    .start = p.start + to_delete,
                    .length = p.length - to_delete,
                };
            } else if (rel + to_delete == p.length) {
                // Trim from end
                self.pieces.items[idx] = Piece{
                    .source = p.source,
                    .start = p.start,
                    .length = rel,
                };
            } else {
                // Split: keep left and right, removing middle
                const left = Piece{
                    .source = p.source,
                    .start = p.start,
                    .length = rel,
                };
                const right = Piece{
                    .source = p.source,
                    .start = p.start + rel + to_delete,
                    .length = p.length - rel - to_delete,
                };
                self.pieces.items[idx] = left;
                try self.pieces.insert(self.allocator, idx + 1, right);
            }

            remaining -= to_delete;
        }
        self.refreshCaches();
    }

    /// Get the byte at a given position from the appropriate source buffer.
    fn sourceByte(self: *const PieceTable, piece: Piece, offset: u32) u8 {
        return switch (piece.source) {
            .original => self.original[piece.start + offset],
            .add => self.add_buffer.items[piece.start + offset],
        };
    }

    /// Get a slice from the appropriate source buffer.
    fn sourceSlice(self: *const PieceTable, piece: Piece) []const u8 {
        return switch (piece.source) {
            .original => self.original[piece.start..][0..piece.length],
            .add => self.add_buffer.items[piece.start..][0..piece.length],
        };
    }

    /// Copy the entire content into a contiguous buffer.
    pub fn getContent(self: *const PieceTable, allocator: Allocator) ![]u8 {
        const total = self.totalLength();
        const buf = try allocator.alloc(u8, total);
        var written: usize = 0;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            @memcpy(buf[written..][0..slice.len], slice);
            written += slice.len;
        }
        return buf;
    }

    /// Get a single byte at a document offset.
    pub fn byteAt(self: *const PieceTable, pos: u32) ?u8 {
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            if (pos < offset + p.length) {
                return self.sourceByte(p, pos - offset);
            }
            offset += p.length;
        }
        return null;
    }

    /// Count newlines in the document (cached).
    pub fn lineCount(self: *const PieceTable) u32 {
        if (self.cached_line_count) |c| return c;
        var count: u32 = 1;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (b == '\n') count += 1;
            }
        }
        return count;
    }

    fn refreshCaches(self: *PieceTable) void {
        // Recompute total length
        var len: u32 = 0;
        for (self.pieces.items) |p| {
            len += p.length;
        }
        self.cached_total_length = len;

        // Recompute line count
        var count: u32 = 1;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (b == '\n') count += 1;
            }
        }
        self.cached_line_count = count;
    }

    /// Get the byte offset of the start of line `line` (0-based line number).
    pub fn lineStart(self: *const PieceTable, line: u32) u32 {
        if (line == 0) return 0;
        var current_line: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (b == '\n') {
                    current_line += 1;
                    if (current_line == line) return offset + 1;
                }
                offset += 1;
            }
        }
        return offset;
    }

    /// Get the byte offset of the end of line (before newline or at EOF).
    pub fn lineEnd(self: *const PieceTable, line: u32) u32 {
        var current_line: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (current_line == line and b == '\n') return offset;
                if (b == '\n') current_line += 1;
                offset += 1;
            }
        }
        return offset;
    }

    /// Get the line number and column for a byte offset.
    pub fn posToLineCol(self: *const PieceTable, pos: u32) struct { line: u32, col: u32 } {
        var line: u32 = 0;
        var col: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (offset == pos) return .{ .line = line, .col = col };
                if (b == '\n') {
                    line += 1;
                    col = 0;
                } else {
                    col += 1;
                }
                offset += 1;
            }
        }
        return .{ .line = line, .col = col };
    }

    /// Get byte offset from line/col (0-based).
    pub fn lineColToPos(self: *const PieceTable, line: u32, col: u32) u32 {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        const max_col = end - start;
        return start + @min(col, max_col);
    }

    /// Get the content of a specific line (without newline).
    pub fn lineContent(self: *const PieceTable, allocator: Allocator, line: u32) ![]u8 {
        const start = self.lineStart(line);
        const end = self.lineEnd(line);
        if (end <= start) return try allocator.alloc(u8, 0);
        return self.getRange(allocator, start, end);
    }

    /// Get content in a byte range. Walks pieces directly (O(pieces + range)).
    pub fn getRange(self: *const PieceTable, allocator: Allocator, start: u32, end: u32) ![]u8 {
        const len = end - start;
        const buf = try allocator.alloc(u8, len);
        var written: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            const piece_end = offset + p.length;
            if (piece_end <= start) {
                offset = piece_end;
                continue;
            }
            if (offset >= end) break;
            const slice = self.sourceSlice(p);
            const copy_start = if (start > offset) start - offset else 0;
            const copy_end = if (end < piece_end) end - offset else p.length;
            const segment = slice[copy_start..copy_end];
            @memcpy(buf[written..][0..segment.len], segment);
            written += @intCast(segment.len);
            offset = piece_end;
        }
        return buf;
    }

    /// Get line start/end offsets for lines [first_line, last_line) in a single pass.
    pub fn getLineOffsets(self: *const PieceTable, first_line: u32, last_line: u32, starts: []u32, ends: []u32) void {
        const count = last_line - first_line;
        if (count == 0) return;
        var current_line: u32 = 0;
        var offset: u32 = 0;
        var filled: u32 = 0;
        // Fill starts for lines in range
        if (first_line == 0) {
            starts[0] = 0;
            filled = 1;
        }
        for (self.pieces.items) |p| {
            if (filled >= count and current_line >= last_line) break;
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (b == '\n') {
                    // This newline ends current_line
                    if (current_line >= first_line and current_line < last_line) {
                        ends[current_line - first_line] = offset;
                    }
                    current_line += 1;
                    // Next char starts new line
                    if (current_line >= first_line and current_line < last_line) {
                        starts[current_line - first_line] = offset + 1;
                        filled += 1;
                    }
                }
                offset += 1;
            }
        }
        // Handle last line (no trailing newline)
        while (filled < count) : (filled += 1) {
            const idx = first_line + filled;
            if (idx >= first_line and idx < last_line) {
                if (starts[idx - first_line] == 0 and idx > 0) {
                    starts[idx - first_line] = offset;
                }
                ends[idx - first_line] = offset;
            }
        }
        // Fill any remaining ends for lines that extend to EOF
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (ends[i] == 0 and i + first_line >= current_line) {
                ends[i] = offset;
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────
test "PieceTable: empty" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 0), pt.totalLength());
}

test "PieceTable: init with content" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "hello world");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 11), pt.totalLength());
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "PieceTable: insert at beginning" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "world");
    defer pt.deinit();
    try pt.insert(0, "hello ");
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "PieceTable: insert in middle" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "helo");
    defer pt.deinit();
    try pt.insert(2, "l");
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "PieceTable: insert at end" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "hello");
    defer pt.deinit();
    try pt.insert(5, " world");
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello world", content);
}

test "PieceTable: delete from middle" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "hello world");
    defer pt.deinit();
    try pt.delete(5, 6);
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "PieceTable: delete from beginning" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "hello world");
    defer pt.deinit();
    try pt.delete(0, 6);
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("world", content);
}

test "PieceTable: line operations" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "line1\nline2\nline3");
    defer pt.deinit();
    try std.testing.expectEqual(@as(u32, 3), pt.lineCount());
    try std.testing.expectEqual(@as(u32, 0), pt.lineStart(0));
    try std.testing.expectEqual(@as(u32, 6), pt.lineStart(1));
    try std.testing.expectEqual(@as(u32, 12), pt.lineStart(2));
    try std.testing.expectEqual(@as(u32, 5), pt.lineEnd(0));
    try std.testing.expectEqual(@as(u32, 11), pt.lineEnd(1));

    const lc = pt.posToLineCol(8);
    try std.testing.expectEqual(@as(u32, 1), lc.line);
    try std.testing.expectEqual(@as(u32, 2), lc.col);
}
