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

    pub fn addGlyph(self: *Atlas, codepoint: u32, bitmap: []const u8, glyph_w: u32, glyph_h: u32, bearing_x: f32, bearing_y: f32, advance: f32) !void {
        if (self.cursor_x + glyph_w > self.width) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height + 1;
            self.row_height = 0;
        }

        if (self.cursor_y + glyph_h > self.height) return;

        var y: u32 = 0;
        while (y < glyph_h) : (y += 1) {
            var x: u32 = 0;
            while (x < glyph_w) : (x += 1) {
                const src_idx = y * glyph_w + x;
                const dst_idx = (self.cursor_y + y) * self.width + (self.cursor_x + x);
                if (src_idx < bitmap.len and dst_idx < self.data.len) {
                    self.data[dst_idx] = bitmap[src_idx];
                }
            }
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
    }

    pub fn needsUpdate(self: *const Atlas) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *Atlas) void {
        self.dirty = false;
        self.resized = false;
    }
};
