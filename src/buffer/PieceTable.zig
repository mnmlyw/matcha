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
    /// Cached byte offsets where each line starts. line_starts[i] = byte offset of line i.
    line_starts: std.ArrayListUnmanaged(u32) = .empty,
    /// Last-resolved (piece_index, logical_offset_of_that_piece) for byteAt.
    /// Sequential or nearby accesses can resume from here instead of walking
    /// pieces from index 0 every call. Cleared on any mutation.
    hint_piece_idx: u32 = 0,
    hint_piece_offset: u32 = 0,

    pub fn init(allocator: Allocator) PieceTable {
        return .{
            .allocator = allocator,
            .original = &.{},
            .original_owned = false,
            .add_buffer = .empty,
            .pieces = .empty,
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
        try pt.refreshCaches();
        return pt;
    }

    pub fn deinit(self: *PieceTable) void {
        if (self.original_owned) {
            self.allocator.free(self.original);
        }
        self.add_buffer.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
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

        if (self.pieces.items.len == 0) {
            try self.pieces.append(self.allocator, .{ .source = .add, .start = add_start, .length = @intCast(text.len) });
            try self.applyInsertToLineCache(pos, text);
            return;
        }

        // Find which piece contains `pos`. Resume from the byteAt hint when
        // possible — consecutive insertions at growing positions (typing
        // forward) hit the same or next piece each call, so restarting at
        // index 0 each time is wasted work.
        var idx: usize = self.hint_piece_idx;
        var offset: u32 = self.hint_piece_offset;
        if (idx >= self.pieces.items.len or offset > pos) {
            idx = 0;
            offset = 0;
        }
        while (idx < self.pieces.items.len) : (idx += 1) {
            const p = self.pieces.items[idx];
            if (pos <= offset + p.length) break;
            offset += p.length;
        }

        // A piece ending exactly at `pos` that already covers the add-buffer
        // bytes immediately preceding the ones we just appended (i.e. it was
        // the last piece appended to add_buffer) can simply be extended in
        // place, rather than allocating a new Piece and shifting the array.
        // This is the hot path for sequential typing, where each keystroke
        // inserts right where the previous one ended: without it, N
        // keystrokes produce N pieces, and every piece walk (insert/delete
        // locate, getContent, refreshCaches) becomes O(N).
        const coalesce_idx: ?usize = if (idx >= self.pieces.items.len)
            (if (self.pieces.items.len > 0) self.pieces.items.len - 1 else null)
        else coalesce: {
            const p = self.pieces.items[idx];
            const rel = pos - offset;
            if (rel == 0) break :coalesce (if (idx > 0) idx - 1 else null);
            if (rel == p.length) break :coalesce idx;
            break :coalesce null; // pos falls strictly inside pieces[idx]: must split
        };
        if (coalesce_idx) |ci| {
            const prev = &self.pieces.items[ci];
            if (prev.source == .add and prev.start + prev.length == add_start) {
                prev.length += @intCast(text.len);
                try self.applyInsertToLineCache(pos, text);
                return;
            }
        }

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .length = @intCast(text.len),
        };

        if (idx >= self.pieces.items.len) {
            // Append at end
            try self.pieces.append(self.allocator, new_piece);
            try self.applyInsertToLineCache(pos, text);
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
        try self.applyInsertToLineCache(pos, text);
    }

    /// Delete `len` bytes starting at byte offset `pos`.
    pub fn delete(self: *PieceTable, pos: u32, len: u32) !void {
        if (len == 0) return;

        var remaining = len;

        // Locate the piece containing `pos` once; subsequent iterations stay
        // at the same logical offset (`pos`), and after any whole-piece removal
        // or trim-from-start the same `idx` already points at the next piece —
        // there is no need to rescan from index 0 each time.
        var offset: u32 = 0;
        var idx: usize = 0;
        while (idx < self.pieces.items.len) : (idx += 1) {
            const p = self.pieces.items[idx];
            if (pos < offset + p.length) break;
            offset += p.length;
        }

        while (remaining > 0 and idx < self.pieces.items.len) {
            const p = self.pieces.items[idx];
            const rel = pos - offset;
            const avail = p.length - rel;
            const to_delete = @min(remaining, avail);

            if (rel == 0 and to_delete == p.length) {
                // Remove entire piece. `idx` now points at the next piece, and
                // `offset` is unchanged because we're still at the same byte
                // position `pos` (the new piece at this idx starts there).
                _ = self.pieces.orderedRemove(idx);
            } else if (rel == 0) {
                // Trim from start. This branch only fires when `to_delete <
                // p.length`, which implies `to_delete == remaining`, so the
                // loop terminates after this iteration — no index advance is
                // needed.
                self.pieces.items[idx] = Piece{
                    .source = p.source,
                    .start = p.start + to_delete,
                    .length = p.length - to_delete,
                };
            } else if (rel + to_delete == p.length) {
                // Trim from end. The next byte to delete lives in the next piece.
                self.pieces.items[idx] = Piece{
                    .source = p.source,
                    .start = p.start,
                    .length = rel,
                };
                offset += rel;
                idx += 1;
            } else {
                // Split: keep left and right, removing middle. We've now
                // consumed everything for this delete; the loop will exit.
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
        self.applyDeleteToLineCache(pos, len);
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

    /// Copy the entire content into a contiguous, null-terminated buffer in
    /// a single allocation and pass. Used at the C ABI boundary, which needs
    /// a sentinel-terminated result — building that by calling `getContent`
    /// and then copying again into a sentinel buffer would scan and copy the
    /// whole document twice per call.
    pub fn getContentZ(self: *const PieceTable, allocator: Allocator) ![:0]u8 {
        const total = self.totalLength();
        const buf = try allocator.allocSentinel(u8, total, 0);
        var written: usize = 0;
        for (self.pieces.items) |p| {
            const slice = self.sourceSlice(p);
            @memcpy(buf[written..][0..slice.len], slice);
            written += slice.len;
        }
        return buf;
    }

    /// Get a single byte at a document offset.
    ///
    /// Uses a piece-index hint so sequential or nearby calls (UTF-8 cluster
    /// scans, bracket matching, word-boundary walks) don't restart from
    /// piece 0 each time. The hint is purely a read-cache — invalidated to
    /// (0, 0) on every mutation by refreshCaches.
    pub fn byteAt(self: *const PieceTable, pos: u32) ?u8 {
        const items = self.pieces.items;
        if (items.len == 0) return null;

        // Try the hint piece first.
        var start_idx: usize = self.hint_piece_idx;
        var start_offset: u32 = self.hint_piece_offset;
        if (start_idx >= items.len or start_offset > pos) {
            // Hint is past the target or stale — restart from the beginning.
            start_idx = 0;
            start_offset = 0;
        }

        var offset: u32 = start_offset;
        var idx: usize = start_idx;
        while (idx < items.len) : (idx += 1) {
            const p = items[idx];
            if (pos < offset + p.length) {
                // Update the hint via @constCast — this is a read-only
                // performance cache; the same pattern as cached_total_length
                // / cached_line_count which are set in refreshCaches.
                const mut = @constCast(self);
                mut.hint_piece_idx = @intCast(idx);
                mut.hint_piece_offset = offset;
                return self.sourceByte(p, pos - offset);
            }
            offset += p.length;
        }
        return null;
    }

    /// Number of pieces in the table.
    pub fn pieceCount(self: *const PieceTable) usize {
        return self.pieces.items.len;
    }

    /// Direct access to a piece's byte slice (no allocation).
    pub fn pieceBytes(self: *const PieceTable, idx: usize) []const u8 {
        return self.sourceSlice(self.pieces.items[idx]);
    }

    // ── UTF-8 helpers ──────────────────────────────────────────

    /// Returns the byte length of a UTF-8 codepoint from its leading byte.
    pub fn codepointByteLen(byte: u8) u32 {
        if (byte < 0x80) return 1;
        if (byte < 0xC0) return 1; // continuation byte, treat as 1
        if (byte < 0xE0) return 2;
        if (byte < 0xF0) return 3;
        return 4;
    }

    /// Walk backward from `pos` to find the start of the previous codepoint.
    pub fn prevCodepointStart(self: *const PieceTable, pos: u32) u32 {
        if (pos == 0) return 0;
        var p = pos - 1;
        while (p > 0) {
            const b = self.byteAt(p) orelse return pos -| 1;
            if (b < 0x80 or b >= 0xC0) return p; // ASCII or leading byte
            p -= 1;
        }
        return p;
    }

    /// Return the byte position after the codepoint starting at `pos`.
    pub fn nextCodepointStart(self: *const PieceTable, pos: u32) u32 {
        const total = self.totalLength();
        if (pos >= total) return total;
        const b = self.byteAt(pos) orelse return @min(pos + 1, total);
        return @min(pos + codepointByteLen(b), total);
    }

    /// Decode the Unicode codepoint at byte position `pos`.
    pub fn codepointAt(self: *const PieceTable, pos: u32) u32 {
        const b0 = self.byteAt(pos) orelse return 0xFFFD;
        if (b0 < 0x80) return b0;
        if (b0 < 0xC0) return 0xFFFD;
        if (b0 < 0xE0) {
            const b1 = self.byteAt(pos + 1) orelse return 0xFFFD;
            return (@as(u32, b0 & 0x1F) << 6) | @as(u32, b1 & 0x3F);
        }
        if (b0 < 0xF0) {
            const b1 = self.byteAt(pos + 1) orelse return 0xFFFD;
            const b2 = self.byteAt(pos + 2) orelse return 0xFFFD;
            return (@as(u32, b0 & 0x0F) << 12) | (@as(u32, b1 & 0x3F) << 6) | @as(u32, b2 & 0x3F);
        }
        const b1 = self.byteAt(pos + 1) orelse return 0xFFFD;
        const b2 = self.byteAt(pos + 2) orelse return 0xFFFD;
        const b3 = self.byteAt(pos + 3) orelse return 0xFFFD;
        return (@as(u32, b0 & 0x07) << 18) | (@as(u32, b1 & 0x3F) << 12) |
            (@as(u32, b2 & 0x3F) << 6) | @as(u32, b3 & 0x3F);
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

    /// Incrementally updates `line_starts`/`cached_total_length`/
    /// `cached_line_count` for an insertion of `text` at byte offset `pos`,
    /// without rescanning the rest of the document. `line_starts` holds
    /// absolute byte offsets in ascending order, so this only needs to:
    /// 1. shift every entry strictly after `pos` right by `text.len`
    ///    (entries exactly at `pos` stay put — the inserted text extends
    ///    that line forward rather than moving its start), and
    /// 2. splice in any new line starts introduced by newlines in `text`.
    fn applyInsertToLineCache(self: *PieceTable, pos: u32, text: []const u8) !void {
        self.hint_piece_idx = 0;
        self.hint_piece_offset = 0;

        if (self.line_starts.items.len == 0) {
            try self.line_starts.append(self.allocator, 0);
        }

        self.cached_total_length = (self.cached_total_length orelse 0) + @as(u32, @intCast(text.len));

        // First index with offset > pos (the boundary between unaffected
        // entries and ones that need to shift).
        const lo = std.sort.upperBound(u32, self.line_starts.items, pos, struct {
            fn order(ctx: u32, item: u32) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.order);

        for (self.line_starts.items[lo..]) |*s| s.* += @intCast(text.len);

        var new_starts: std.ArrayListUnmanaged(u32) = .empty;
        defer new_starts.deinit(self.allocator);
        for (text, 0..) |b, i| {
            if (b == '\n') try new_starts.append(self.allocator, pos + @as(u32, @intCast(i)) + 1);
        }
        if (new_starts.items.len > 0) {
            try self.line_starts.insertSlice(self.allocator, lo, new_starts.items);
        }

        self.cached_line_count = @intCast(self.line_starts.items.len);
    }

    /// Incrementally updates `line_starts`/`cached_total_length`/
    /// `cached_line_count` for a deletion of `len` bytes at offset `pos`,
    /// without rescanning the rest of the document. An entry at `o` is kept
    /// unshifted when `o <= pos` (its defining newline, if any, lies before
    /// the deleted range). An entry with `pos < o <= pos + len` is removed:
    /// its defining newline at `o - 1` always falls inside `[pos, pos+len)`
    /// (since `o - 1 >= pos`), so that line merges into the previous one.
    /// Everything with `o > pos + len` survives and shifts left by `len`.
    /// Never allocates, so it can't fail.
    fn applyDeleteToLineCache(self: *PieceTable, pos: u32, len: u32) void {
        self.hint_piece_idx = 0;
        self.hint_piece_offset = 0;

        self.cached_total_length = (self.cached_total_length orelse 0) - len;

        const items = self.line_starts.items;
        const order = struct {
            fn order(ctx: u32, item: u32) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.order;
        const lo = std.sort.upperBound(u32, items, pos, order);
        const boundary = pos + len;
        const hi = std.sort.upperBound(u32, items, boundary, order);

        if (hi > lo) self.line_starts.replaceRangeAssumeCapacity(lo, hi - lo, &.{});
        for (self.line_starts.items[lo..]) |*s| s.* -= len;

        self.cached_line_count = @intCast(self.line_starts.items.len);
    }

    fn refreshCaches(self: *PieceTable) !void {
        // Any mutation invalidates the byteAt hint — piece indices may have
        // shifted from insert/delete/split.
        self.hint_piece_idx = 0;
        self.hint_piece_offset = 0;

        // Single pass: compute total length, line count, and line start offsets
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.allocator, 0); // line 0 starts at byte 0

        var len: u32 = 0;
        var offset: u32 = 0;
        for (self.pieces.items) |p| {
            len += p.length;
            const slice = self.sourceSlice(p);
            for (slice) |b| {
                if (b == '\n') {
                    try self.line_starts.append(self.allocator, offset + 1);
                }
                offset += 1;
            }
        }
        self.cached_total_length = len;
        self.cached_line_count = @intCast(self.line_starts.items.len);
    }

    /// O(1) — Get the byte offset of the start of line `line` (0-based).
    pub fn lineStart(self: *const PieceTable, line: u32) u32 {
        if (line < self.line_starts.items.len) return self.line_starts.items[line];
        return self.totalLength();
    }

    /// O(1) — Get the byte offset of the end of line (before newline or at EOF).
    pub fn lineEnd(self: *const PieceTable, line: u32) u32 {
        if (line + 1 < self.line_starts.items.len) return self.line_starts.items[line + 1] - 1;
        return self.totalLength();
    }

    /// O(log n) — Get the line number and column for a byte offset.
    pub fn posToLineCol(self: *const PieceTable, pos: u32) struct { line: u32, col: u32 } {
        const starts = self.line_starts.items;
        if (starts.len == 0) return .{ .line = 0, .col = pos };

        // Binary search for the largest line_start <= pos
        var lo: u32 = 0;
        var hi: u32 = @intCast(starts.len - 1);
        while (lo < hi) {
            const mid = lo + (hi - lo + 1) / 2;
            if (starts[mid] <= pos) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return .{ .line = lo, .col = pos - starts[lo] };
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
        if (start > end or end > self.totalLength()) return error.InvalidRange;
        const len = end - start;
        const buf = try allocator.alloc(u8, len);
        self.copyRange(start, end, buf);
        return buf;
    }

    /// Copy content in a byte range into a caller-provided buffer.
    pub fn copyRange(self: *const PieceTable, start: u32, end: u32, dest: []u8) void {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.totalLength());
        const len = end - start;
        std.debug.assert(dest.len >= len);

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
            @memcpy(dest[written..][0..segment.len], segment);
            written += @intCast(segment.len);
            offset = piece_end;
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

test "PieceTable: delete spanning many pieces" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "abc");
    defer pt.deinit();
    // Build up a piece table with many small pieces in the middle.
    try pt.insert(1, "1");
    try pt.insert(2, "2");
    try pt.insert(3, "3");
    try pt.insert(4, "4");
    try pt.insert(5, "5");
    // Document should now be "a12345bc". Delete everything from index 1..7
    // ("12345b"), which crosses several pieces.
    try pt.delete(1, 6);
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("ac", content);
}

test "PieceTable: delete entire buffer in one call" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "hello world");
    defer pt.deinit();
    try pt.insert(5, "-XYZ-");
    // Now "hello-XYZ- world", len = 16. Delete all of it.
    try pt.delete(0, pt.totalLength());
    try std.testing.expectEqual(@as(u32, 0), pt.totalLength());
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("", content);
}

test "PieceTable: delete crossing whole-piece-removal + continuing" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();
    // Build a layout where deletion will entirely consume one piece and
    // continue into the next.
    try pt.insert(0, "AAA");
    try pt.insert(3, "BBB");
    try pt.insert(6, "CCC");
    // "AAABBBCCC", len 9. Delete BBB and one byte of CCC (range [3, 7)).
    try pt.delete(3, 4);
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("AAACC", content);
}

test "PieceTable: delete from end of one piece into start of next" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();
    try pt.insert(0, "abcd");
    try pt.insert(4, "efgh");
    try pt.insert(8, "ijkl");
    // "abcdefghijkl", len 12. Delete [3, 9) → "abc" + "jkl" = "abcjkl".
    try pt.delete(3, 6);
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("abcjkl", content);
}

test "PieceTable: byteAt hint survives mutation that invalidates it" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "abcdef");
    defer pt.deinit();
    try pt.insert(3, "XYZ"); // "abcXYZdef"

    // Warm the hint by accessing the last piece, then mutate, then access
    // an earlier position. The hint must be invalidated so we don't read
    // stale piece offsets.
    try std.testing.expectEqual(@as(u8, 'f'), pt.byteAt(8).?);
    try pt.insert(0, "@@"); // "@@abcXYZdef"
    try std.testing.expectEqual(@as(u8, '@'), pt.byteAt(0).?);
    try std.testing.expectEqual(@as(u8, 'X'), pt.byteAt(5).?);
    try std.testing.expectEqual(@as(u8, 'f'), pt.byteAt(10).?);
}

test "PieceTable: byteAt hint handles backward access" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();
    try pt.insert(0, "AAA");
    try pt.insert(3, "BBB");
    try pt.insert(6, "CCC");
    // "AAABBBCCC". Walk forward to warm the hint at piece 2, then access
    // an earlier piece — the hint must reset rather than miss.
    try std.testing.expectEqual(@as(u8, 'C'), pt.byteAt(7).?);
    try std.testing.expectEqual(@as(u8, 'A'), pt.byteAt(1).?);
    try std.testing.expectEqual(@as(u8, 'B'), pt.byteAt(4).?);
    try std.testing.expectEqual(@as(u8, 'C'), pt.byteAt(8).?);
}

test "PieceTable: insert hint produces correct content over many forward inserts" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();
    // Simulate typing forward — every insertion is at the current end,
    // which is exactly the access pattern the hint optimizes for.
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const ch: u8 = @intCast(@as(u32, 'a') + (i % 26));
        const buf = [_]u8{ch};
        try pt.insert(i, &buf);
    }
    try std.testing.expectEqual(@as(u32, 64), pt.totalLength());
    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqual(@as(usize, 64), content.len);
    // First/last byte sanity check.
    try std.testing.expectEqual(@as(u8, 'a'), content[0]);
    try std.testing.expectEqual(@as(u8, 'a' + (63 % 26)), content[63]);
}

test "PieceTable: sequential forward inserts coalesce into a single piece" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();

    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        const ch: u8 = @intCast(@as(u32, 'a') + (i % 26));
        const buf = [_]u8{ch};
        try pt.insert(i, &buf);
    }
    // Without coalescing this would be 500 pieces (one per keystroke),
    // making every piece walk O(N). Sequential append-at-end typing must
    // stay a single piece.
    try std.testing.expectEqual(@as(usize, 1), pt.pieceCount());
    try std.testing.expectEqual(@as(u32, 500), pt.totalLength());
}

test "PieceTable: coalescing does not merge across a piece from a different insert site" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "AB");
    defer pt.deinit();

    // Type "x" at the end (new add-buffer piece), then go back and type "y"
    // in the middle of the *original* piece -- this must NOT coalesce with
    // the "x" piece, since "y" isn't adjacent to "x" in add_buffer content
    // or in document position.
    try pt.insert(2, "x"); // "ABx"
    try pt.insert(1, "y"); // "AyBx"

    const content = try pt.getContent(std.testing.allocator);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("AyBx", content);
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

test "PieceTable: invalid ranges are rejected" {
    var pt = try PieceTable.initWithContent(std.testing.allocator, "abc");
    defer pt.deinit();

    try std.testing.expectError(error.InvalidRange, pt.getRange(std.testing.allocator, 2, 1));
    try std.testing.expectError(error.InvalidRange, pt.getRange(std.testing.allocator, 0, 4));
}

test "PieceTable: randomized edits match contiguous model" {
    var pt = PieceTable.init(std.testing.allocator);
    defer pt.deinit();

    var model: std.ArrayListUnmanaged(u8) = .empty;
    defer model.deinit(std.testing.allocator);

    var state: u32 = 0xC0FFEE;
    var step: u32 = 0;
    while (step < 300) : (step += 1) {
        state = state *% 1664525 +% 1013904223;
        const op = state % 3;

        if (op == 0 or model.items.len == 0) {
            state = state *% 1664525 +% 1013904223;
            const pos: usize = if (model.items.len == 0) 0 else state % (model.items.len + 1);
            state = state *% 1664525 +% 1013904223;
            const len: usize = 1 + (state % 8);
            var buf: [8]u8 = undefined;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                state = state *% 1664525 +% 1013904223;
                buf[i] = @as(u8, 'a') + @as(u8, @intCast(state % 26));
            }
            try pt.insert(@intCast(pos), buf[0..len]);
            try model.insertSlice(std.testing.allocator, pos, buf[0..len]);
        } else {
            state = state *% 1664525 +% 1013904223;
            const pos: usize = state % model.items.len;
            state = state *% 1664525 +% 1013904223;
            const max_len = model.items.len - pos;
            const len: usize = 1 + (state % max_len);
            try pt.delete(@intCast(pos), @intCast(len));
            model.replaceRange(std.testing.allocator, pos, len, &.{}) catch unreachable;
        }

        const content = try pt.getContent(std.testing.allocator);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualSlices(u8, model.items, content);
        try std.testing.expectEqual(@as(u32, @intCast(model.items.len)), pt.totalLength());

        // Independently recompute expected line starts from the model and
        // check the piece table's incrementally-maintained line cache
        // (line_starts, via lineCount/lineStart/lineEnd) matches exactly.
        var expected_line_starts: std.ArrayListUnmanaged(u32) = .empty;
        defer expected_line_starts.deinit(std.testing.allocator);
        try expected_line_starts.append(std.testing.allocator, 0);
        for (model.items, 0..) |b, i| {
            if (b == '\n') try expected_line_starts.append(std.testing.allocator, @intCast(i + 1));
        }
        try std.testing.expectEqual(@as(u32, @intCast(expected_line_starts.items.len)), pt.lineCount());
        for (expected_line_starts.items, 0..) |expected_start, line| {
            try std.testing.expectEqual(expected_start, pt.lineStart(@intCast(line)));
            const expected_end = if (line + 1 < expected_line_starts.items.len)
                expected_line_starts.items[line + 1] - 1
            else
                @as(u32, @intCast(model.items.len));
            try std.testing.expectEqual(expected_end, pt.lineEnd(@intCast(line)));
        }
    }
}

