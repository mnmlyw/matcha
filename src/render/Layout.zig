/// Viewport / cell dimension calculations.
pub const Layout = struct {
    viewport_width: u32 = 800,
    viewport_height: u32 = 600,
    cell_width: f32 = 8.0,
    cell_height: f32 = 16.0,
    gutter_width: f32 = 0,

    pub fn visibleCols(self: *const Layout) u32 {
        const text_width = @as(f32, @floatFromInt(self.viewport_width)) - self.gutter_width;
        if (self.cell_width <= 0) return 80;
        return @intFromFloat(text_width / self.cell_width);
    }

    pub fn visibleRows(self: *const Layout) u32 {
        if (self.cell_height <= 0) return 25;
        return @intFromFloat(@as(f32, @floatFromInt(self.viewport_height)) / self.cell_height);
    }

    pub fn cellRect(self: *const Layout, row: u32, col: u32) struct { x: f32, y: f32, w: f32, h: f32 } {
        return .{
            .x = @as(f32, @floatFromInt(col)) * self.cell_width + self.gutter_width,
            .y = @as(f32, @floatFromInt(row)) * self.cell_height,
            .w = self.cell_width,
            .h = self.cell_height,
        };
    }
};
