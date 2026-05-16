const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig").Config;

pub fn parseFile(allocator: Allocator, config: *Config, path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Still record the path so a later set_system_dark can no-op
            // cleanly even if the file appears between calls.
            savePath(config, allocator, path);
            return;
        },
        else => return err,
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(content);

    // First pass: find appearance setting
    try parse(allocator, config, content);
    // Apply theme colors for the chosen appearance
    config.applyAppearance();
    // Second pass: re-apply user color overrides on top of theme
    try parse(allocator, config, content);

    savePath(config, allocator, path);
}

fn savePath(config: *Config, allocator: Allocator, path: []const u8) void {
    // Free any prior path so re-loading the same Config doesn't leak.
    if (config.loaded_path) |old| {
        if (config.allocator) |a| a.free(old) else allocator.free(old);
    }
    config.loaded_path = allocator.dupe(u8, path) catch null;
    config.allocator = allocator;
}

/// Re-apply user overrides on top of whatever theme is currently set.
/// Called by `matcha_config_set_system_dark` after it resolves `auto` and
/// runs `applyAppearance()` — without this, an explicit `bg-color = #xxx`
/// in the user's config would be wiped by the theme colors.
pub fn reapplyUserOverrides(config: *Config) void {
    const path = config.loaded_path orelse return;
    const allocator = config.allocator orelse return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    parse(allocator, config, content) catch {};
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
    } else if (std.mem.eql(u8, key, "auto-update")) {
        config.auto_update = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "appearance")) {
        if (std.mem.eql(u8, value, "dark")) {
            config.appearance = .dark;
        } else if (std.mem.eql(u8, value, "light")) {
            config.appearance = .light;
        } else {
            config.appearance = .auto;
        }
    } else if (std.mem.eql(u8, key, "bg-color")) {
        if (parseColor(value)) |c| config.bg_color = c;
    } else if (std.mem.eql(u8, key, "fg-color")) {
        if (parseColor(value)) |c| config.fg_color = c;
    } else if (std.mem.eql(u8, key, "cursor-color")) {
        if (parseColor(value)) |c| config.cursor_color = c;
    } else if (std.mem.eql(u8, key, "selection-color")) {
        if (parseColor(value)) |c| config.selection_color = c;
    } else if (std.mem.eql(u8, key, "theme-normal-color")) {
        if (parseColor(value)) |c| config.theme.normal = c;
    } else if (std.mem.eql(u8, key, "theme-keyword-color")) {
        if (parseColor(value)) |c| config.theme.keyword = c;
    } else if (std.mem.eql(u8, key, "theme-string-color")) {
        if (parseColor(value)) |c| config.theme.string = c;
    } else if (std.mem.eql(u8, key, "theme-comment-color")) {
        if (parseColor(value)) |c| config.theme.comment = c;
    } else if (std.mem.eql(u8, key, "theme-number-color")) {
        if (parseColor(value)) |c| config.theme.number = c;
    } else if (std.mem.eql(u8, key, "theme-type-color")) {
        if (parseColor(value)) |c| config.theme.typ = c;
    } else if (std.mem.eql(u8, key, "theme-function-color")) {
        if (parseColor(value)) |c| config.theme.function = c;
    } else if (std.mem.eql(u8, key, "theme-operator-color")) {
        if (parseColor(value)) |c| config.theme.operator = c;
    } else if (std.mem.eql(u8, key, "theme-punctuation-color")) {
        if (parseColor(value)) |c| config.theme.punctuation = c;
    } else if (std.mem.eql(u8, key, "theme-attribute-color")) {
        if (parseColor(value)) |c| config.theme.attribute = c;
    }
    // Unknown keys are silently ignored
}

fn parseColor(value: []const u8) ?u32 {
    var hex = value;
    if (hex.len > 0 and hex[0] == '#') hex = hex[1..];
    if (hex.len == 6) {
        const rgb = std.fmt.parseInt(u32, hex, 16) catch return null;
        return (rgb << 8) | 0xFF;
    }
    if (hex.len == 8) {
        return std.fmt.parseInt(u32, hex, 16) catch null;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────

test "Parser: set_system_dark preserves user bg-color override" {
    var config = Config.defaults();
    defer config.deinit();
    config.allocator = std.testing.allocator;

    // User sets explicit bg-color and leaves appearance at auto.
    try parse(std.testing.allocator, &config,
        \\bg-color = #1a1a1a
    );
    try std.testing.expectEqual(@as(u32, 0x1a1a1aFF), config.bg_color);

    // Simulate what main_c.zig:matcha_config_set_system_dark does for a dark
    // system, WITHOUT the reapplyUserOverrides fix:
    config.appearance = .dark;
    config.applyAppearance();
    config.appearance = .auto;
    // applyAppearance just overwrote bg_color with the dark theme default —
    // the user's override is lost until we re-overlay it.
    try std.testing.expect(config.bg_color != 0x1a1a1aFF);

    // The fix re-parses the saved config. For this test we simulate by
    // running parse() again directly (reapplyUserOverrides would do the
    // same after reading the file from `loaded_path`).
    try parse(std.testing.allocator, &config,
        \\bg-color = #1a1a1a
    );
    try std.testing.expectEqual(@as(u32, 0x1a1a1aFF), config.bg_color);
}

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
