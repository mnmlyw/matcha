/// Font-level metrics.
pub const FontMetrics = struct {
    ascent: f32 = 12.0,
    descent: f32 = 4.0,
    leading: f32 = 0.0,
    line_height: f32 = 16.0,
    cell_width: f32 = 8.0,
    underline_position: f32 = 14.0,
    underline_thickness: f32 = 1.0,

    pub fn fromFontSize(size: f32) FontMetrics {
        // Approximate metrics for a typical monospace font
        const ascent = size * 0.85;
        const descent = size * 0.25;
        const leading = size * 0.05;
        return .{
            .ascent = ascent,
            .descent = descent,
            .leading = leading,
            .line_height = ascent + descent + leading,
            .cell_width = size * 0.6,
            .underline_position = ascent + descent * 0.5,
            .underline_thickness = @max(1.0, size / 14.0),
        };
    }
};
