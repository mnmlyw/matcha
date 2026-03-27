const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig").Config;

pub fn parseFile(allocator: Allocator, config: *Config, path: []const u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    // First pass: find appearance setting
    try parse(allocator, config, content);
    // Apply theme colors for the chosen appearance
    config.applyAppearance();
    // Second pass: re-apply user color overrides on top of theme
    try parse(allocator, config, content);
}

pub fn parse(allocator: Allocator, config: *Config, content: []const u8) !void {
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], " \t");
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

        try applyKeyValue(allocator, config, key, value);
    }
}

fn applyKeyValue(allocator: Allocator, config: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "font-family")) {
        try config.setFontFamily(allocator, value);
    } else if (std.mem.eql(u8, key, "font-size")) {
        config.font_size = std.fmt.parseFloat(f64, value) catch 14.0;
    } else if (std.mem.eql(u8, key, "tab-size")) {
        config.tab_size = std.fmt.parseInt(u32, value, 10) catch 4;
    } else if (std.mem.eql(u8, key, "insert-spaces")) {
        config.insert_spaces = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "line-numbers")) {
        config.line_numbers = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "wrap-lines")) {
        config.wrap_lines = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "appearance")) {
        if (std.mem.eql(u8, value, "dark")) {
            config.appearance = .dark;
        } else if (std.mem.eql(u8, value, "light")) {
            config.appearance = .light;
        } else {
            config.appearance = .auto;
        }
    } else if (std.mem.eql(u8, key, "bg-color")) {
        config.bg_color = parseColor(value);
    } else if (std.mem.eql(u8, key, "fg-color")) {
        config.fg_color = parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        config.cursor_color = parseColor(value);
    } else if (std.mem.eql(u8, key, "selection-color")) {
        config.selection_color = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-normal-color")) {
        config.theme.normal = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-keyword-color")) {
        config.theme.keyword = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-string-color")) {
        config.theme.string = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-comment-color")) {
        config.theme.comment = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-number-color")) {
        config.theme.number = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-type-color")) {
        config.theme.typ = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-function-color")) {
        config.theme.function = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-operator-color")) {
        config.theme.operator = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-punctuation-color")) {
        config.theme.punctuation = parseColor(value);
    } else if (std.mem.eql(u8, key, "theme-attribute-color")) {
        config.theme.attribute = parseColor(value);
    }
    // Unknown keys are silently ignored
}

fn parseColor(value: []const u8) u32 {
    var hex = value;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len == 6) {
        // Add FF alpha
        const rgb = std.fmt.parseInt(u32, hex, 16) catch return 0;
        return (rgb << 8) | 0xFF;
    }
    if (hex.len == 8) {
        return std.fmt.parseInt(u32, hex, 16) catch 0;
    }
    return 0;
}

// ── Tests ──────────────────────────────────────────────────────
test "Parser: parse config" {
    var config = Config.defaults();
    defer config.deinit();

    try parse(std.testing.allocator, &config,
        \\# Matcha config
        \\font-family = Berkeley Mono
        \\font-size = 16
        \\tab-size = 2
        \\insert-spaces = true
        \\line-numbers = false
    );

    try std.testing.expectEqualStrings("Berkeley Mono", config.font_family);
    try std.testing.expectEqual(@as(f64, 16.0), config.font_size);
    try std.testing.expectEqual(@as(u32, 2), config.tab_size);
    try std.testing.expect(config.insert_spaces);
    try std.testing.expect(!config.line_numbers);
}
