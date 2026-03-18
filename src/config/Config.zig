const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Theme = @import("../highlight/TokenType.zig").Theme;

pub const Config = struct {
    allocator: ?Allocator = null,

    font_family: []const u8 = "SF Mono",
    font_family_owned: bool = false,
    font_size: f64 = 14.0,
    tab_size: u32 = 4,
    insert_spaces: bool = true,
    line_numbers: bool = true,
    wrap_lines: bool = true,

    // Theme colors (RGBA) – cyberdream
    bg_color: u32 = 0x16181AFF, // bg
    fg_color: u32 = 0xFFFFFFFF, // fg
    cursor_color: u32 = 0xFFFFFFFF,
    selection_color: u32 = 0x3C404880,
    current_line_color: u32 = 0xFFFFFF0A, // subtle highlight on cursor line
    trailing_ws_color: u32 = 0xFF5C5C30, // dim red for trailing whitespace
    gutter_fg_color: u32 = 0x7B8496FF, // grey
    gutter_bg_color: u32 = 0x16181AFF, // bg (same as text bg)
    line_number_color: u32 = 0x7B8496FF, // grey
    current_line_number_color: u32 = 0xFFFFFFFF, // bright white for active line number

    // Syntax theme
    theme: Theme = .{},

    pub fn defaults() Config {
        return .{};
    }

    pub fn deinit(self: *Config) void {
        if (self.font_family_owned) {
            if (self.allocator) |alloc| {
                alloc.free(self.font_family);
            }
        }
    }

    pub fn setFontFamily(self: *Config, alloc: Allocator, family: []const u8) !void {
        if (self.font_family_owned) {
            if (self.allocator) |a| a.free(self.font_family);
        }
        self.font_family = try alloc.dupe(u8, family);
        self.font_family_owned = true;
        self.allocator = alloc;
    }
};
