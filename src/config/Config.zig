const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Theme = @import("../highlight/TokenType.zig").Theme;

pub const Config = struct {
    allocator: ?Allocator = null,

    font_family: []const u8 = "SF Mono",
    font_family_owned: bool = false,
    font_size: f64 = 16.0,
    tab_size: u32 = 4,
    insert_spaces: bool = true,
    line_numbers: bool = true,

    // Theme colors (RGBA)
    bg_color: u32 = 0x1E1E2EFF, // dark background
    fg_color: u32 = 0xCDD6F4FF, // light text
    cursor_color: u32 = 0xF5E0DCFF,
    selection_color: u32 = 0x45475A80,
    gutter_fg_color: u32 = 0x6C7086FF,
    gutter_bg_color: u32 = 0x181825FF,
    line_number_color: u32 = 0x6C7086FF,

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
