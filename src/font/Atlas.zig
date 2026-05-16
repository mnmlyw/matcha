const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GlyphInfo = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    uv_x: f32,
    uv_y: f32,
    uv_w: f32,
    uv_h: f32,
    bearing_x: f32,
    bearing_y: f32,
    advance: f32,
};

pub const Atlas = struct {
    allocator: Allocator,
    width: u32,
    height: u32,
    data: []u8,
    glyphs: std.AutoHashMapUnmanaged(u32, GlyphInfo),

    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_height: u32 = 0,

    dirty: bool = true,
    resized: bool = true,

    pub fn init(allocator: Allocator) !Atlas {
        const width: u32 = 1024;
        const height: u32 = 1024;
        const data = try allocator.alloc(u8, width * height);
        @memset(data, 0);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .data = data,
            .glyphs = .{},
        };
    }

    pub fn deinit(self: *Atlas) void {
        self.allocator.free(self.data);
        self.glyphs.deinit(self.allocator);
    }

    pub fn getGlyph(self: *Atlas, codepoint: u32) ?GlyphInfo {
        return self.glyphs.get(codepoint);
    }

    /// Returns true if the glyph was inserted. Returns false when the atlas
    /// is full — callers should not cache a successful result in that case so
    /// a later frame (after eviction or atlas growth) can retry.
    pub fn addGlyph(self: *Atlas, codepoint: u32, bitmap: []const u8, glyph_w: u32, glyph_h: u32, bearing_x: f32, bearing_y: f32, advance: f32) !bool {
        if (glyph_w == 0 or glyph_h == 0) return false;
        if (glyph_w > self.width or glyph_h > self.height) return false;

        if (self.cursor_x + glyph_w > self.width) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height + 1;
            self.row_height = 0;
        }

        if (self.cursor_y + glyph_h > self.height) return false;

        // Row-at-a-time @memcpy beats per-pixel for ~10× lower overhead in the
        // hot path of first-paint with many new glyphs.
        var y: u32 = 0;
        while (y < glyph_h) : (y += 1) {
            const src_off = y * glyph_w;
            const dst_off = (self.cursor_y + y) * self.width + self.cursor_x;
            const row_len = @min(glyph_w, @as(u32, @intCast(@min(
                bitmap.len -| src_off,
                self.data.len -| dst_off,
            ))));
            if (row_len == 0) continue;
            @memcpy(self.data[dst_off..][0..row_len], bitmap[src_off..][0..row_len]);
        }

        const atlas_w_f: f32 = @floatFromInt(self.width);
        const atlas_h_f: f32 = @floatFromInt(self.height);

        try self.glyphs.put(self.allocator, codepoint, .{
            .x = self.cursor_x,
            .y = self.cursor_y,
            .width = glyph_w,
            .height = glyph_h,
            .uv_x = @as(f32, @floatFromInt(self.cursor_x)) / atlas_w_f,
            .uv_y = @as(f32, @floatFromInt(self.cursor_y)) / atlas_h_f,
            .uv_w = @as(f32, @floatFromInt(glyph_w)) / atlas_w_f,
            .uv_h = @as(f32, @floatFromInt(glyph_h)) / atlas_h_f,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance = advance,
        });

        self.cursor_x += glyph_w + 1;
        self.row_height = @max(self.row_height, glyph_h);
        self.dirty = true;
        return true;
    }

    pub fn needsUpdate(self: *const Atlas) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *Atlas) void {
        self.dirty = false;
        self.resized = false;
    }
};
