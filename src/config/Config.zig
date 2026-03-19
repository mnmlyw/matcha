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

    // Appearance: "light" or "dark"
    appearance: Appearance = .light,

    // Theme colors (set by applyAppearance)
    bg_color: u32 = 0xFAFAF8FF,
    fg_color: u32 = 0x2A2A2AFF,
    cursor_color: u32 = 0x3A7D34FF,
    selection_color: u32 = 0x6BBE5A30,
    current_line_color: u32 = 0x6BBE5A10,
    trailing_ws_color: u32 = 0xE0685028,
    gutter_fg_color: u32 = 0xB0B0A8FF,
    gutter_bg_color: u32 = 0xF2F2EEFF,
    line_number_color: u32 = 0xB0B0A8FF,
    current_line_number_color: u32 = 0x3A7D34FF,
    // Chrome colors for Swift UI (tab bar, status bar, find bar, clear color)
    chrome_bg_color: u32 = 0xF2F2EEFF,
    chrome_active_bg_color: u32 = 0xFAFAF8FF,
    chrome_fg_color: u32 = 0x2A2A2AFF,
    chrome_dim_color: u32 = 0x999990FF,

    // Syntax theme
    theme: Theme = .{
        .normal = 0x2A2A2AFF,
        .keyword = 0x7C3AEDFF,
        .string = 0x3A7D34FF,
        .comment = 0xA0A090FF,
        .number = 0xC05620FF,
        .typ = 0x1A6DB5FF,
        .function = 0x8B5CF6FF,
        .operator = 0x7C3AEDFF,
        .punctuation = 0x555555FF,
        .attribute = 0x0D7D7DFF,
    },

    pub const Appearance = enum {
        light,
        dark,
    };

    pub fn applyAppearance(self: *Config) void {
        switch (self.appearance) {
            .light => {
                self.bg_color = 0xFAFAF8FF;
                self.fg_color = 0x2A2A2AFF;
                self.cursor_color = 0x3A7D34FF;
                self.selection_color = 0x6BBE5A30;
                self.current_line_color = 0x6BBE5A10;
                self.trailing_ws_color = 0xE0685028;
                self.gutter_fg_color = 0xB0B0A8FF;
                self.gutter_bg_color = 0xF2F2EEFF;
                self.line_number_color = 0xB0B0A8FF;
                self.current_line_number_color = 0x3A7D34FF;
                self.chrome_bg_color = 0xF2F2EEFF;
                self.chrome_active_bg_color = 0xFAFAF8FF;
                self.chrome_fg_color = 0x2A2A2AFF;
                self.chrome_dim_color = 0x999990FF;
                self.theme = .{
                    .normal = 0x2A2A2AFF,
                    .keyword = 0x7C3AEDFF,
                    .string = 0x3A7D34FF,
                    .comment = 0xA0A090FF,
                    .number = 0xC05620FF,
                    .typ = 0x1A6DB5FF,
                    .function = 0x8B5CF6FF,
                    .operator = 0x7C3AEDFF,
                    .punctuation = 0x555555FF,
                    .attribute = 0x0D7D7DFF,
                };
            },
            .dark => {
                self.bg_color = 0x1A1D20FF;
                self.fg_color = 0xE0E0D8FF;
                self.cursor_color = 0x7ECF6AFF;
                self.selection_color = 0x6BBE5A30;
                self.current_line_color = 0x6BBE5A0A;
                self.trailing_ws_color = 0xFF5C5C28;
                self.gutter_fg_color = 0x606058FF;
                self.gutter_bg_color = 0x1A1D20FF;
                self.line_number_color = 0x606058FF;
                self.current_line_number_color = 0x7ECF6AFF;
                self.chrome_bg_color = 0x15171AFF;
                self.chrome_active_bg_color = 0x1A1D20FF;
                self.chrome_fg_color = 0xE0E0D8FF;
                self.chrome_dim_color = 0x707068FF;
                self.theme = .{
                    .normal = 0xE0E0D8FF,
                    .keyword = 0xC4A7FEFF,
                    .string = 0x7ECF6AFF,
                    .comment = 0x606058FF,
                    .number = 0xF0A050FF,
                    .typ = 0x6CB6FFFF,
                    .function = 0xAA8EFFFF,
                    .operator = 0xC4A7FEFF,
                    .punctuation = 0xA0A098FF,
                    .attribute = 0x5EE0D0FF,
                };
            },
        }
    }

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
