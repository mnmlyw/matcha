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

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on"))
        return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off"))
        return false;
    return null;
}

fn applyKeyValue(allocator: Allocator, config: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "font-family")) {
        try config.setFontFamily(allocator, value);
    } else if (std.mem.eql(u8, key, "font-size")) {
        // Keep the current value on parse failure rather than silently
        // resetting to the default — protects against typos. `parseFloat`
        // accepts "inf"/absurd magnitudes like "1e308"; those (and NaN)
        // must be rejected here too, or they reach font/atlas creation as
        // infinite/NaN glyph metrics and crash or hang at launch. Cap to a
        // sane range, matching the tab-size guard just below.
        if (std.fmt.parseFloat(f64, value)) |v| {
            if (v >= 1 and v <= 512 and std.math.isFinite(v)) config.font_size = v;
        } else |_| {}
    } else if (std.mem.eql(u8, key, "tab-size")) {
        if (std.fmt.parseInt(u32, value, 10)) |v| {
            // tab-size = 0 would divide-by-zero in tabVisualWidth. Cap to
            // a sane range.
            if (v >= 1 and v <= 32) config.tab_size = v;
        } else |_| {}
    } else if (std.mem.eql(u8, key, "insert-spaces")) {
        if (parseBool(value)) |v| config.insert_spaces = v;
    } else if (std.mem.eql(u8, key, "line-numbers")) {
        if (parseBool(value)) |v| config.line_numbers = v;
    } else if (std.mem.eql(u8, key, "wrap-lines")) {
        if (parseBool(value)) |v| config.wrap_lines = v;
    } else if (std.mem.eql(u8, key, "auto-update")) {
        if (parseBool(value)) |v| config.auto_update = v;
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
    } else if (std.mem.eql(u8, key, "current-line-color")) {
        if (parseColor(value)) |c| config.current_line_color = c;
    } else if (std.mem.eql(u8, key, "trailing-ws-color")) {
        if (parseColor(value)) |c| config.trailing_ws_color = c;
    } else if (std.mem.eql(u8, key, "indent-guide-color")) {
        if (parseColor(value)) |c| config.indent_guide_color = c;
    } else if (std.mem.eql(u8, key, "gutter-fg-color")) {
        if (parseColor(value)) |c| config.gutter_fg_color = c;
    } else if (std.mem.eql(u8, key, "gutter-bg-color")) {
        if (parseColor(value)) |c| config.gutter_bg_color = c;
    } else if (std.mem.eql(u8, key, "line-number-color")) {
        if (parseColor(value)) |c| config.line_number_color = c;
    } else if (std.mem.eql(u8, key, "current-line-number-color")) {
        if (parseColor(value)) |c| config.current_line_number_color = c;
    } else if (std.mem.eql(u8, key, "chrome-bg-color")) {
        if (parseColor(value)) |c| config.chrome_bg_color = c;
    } else if (std.mem.eql(u8, key, "chrome-active-bg-color")) {
        if (parseColor(value)) |c| config.chrome_active_bg_color = c;
    } else if (std.mem.eql(u8, key, "chrome-fg-color")) {
        if (parseColor(value)) |c| config.chrome_fg_color = c;
    } else if (std.mem.eql(u8, key, "chrome-dim-color")) {
        if (parseColor(value)) |c| config.chrome_dim_color = c;
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
    if (hex.len == 3) {
        // #rgb shorthand — each digit doubled. #f0a → 0xFF00AAFF.
        const v = std.fmt.parseInt(u32, hex, 16) catch return null;
        const r = (v >> 8) & 0xF;
        const g = (v >> 4) & 0xF;
        const b = v & 0xF;
        return ((r * 0x11) << 24) | ((g * 0x11) << 16) | ((b * 0x11) << 8) | 0xFF;
    }
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

test "Parser: parseFile + reapplyUserOverrides preserves user color after appearance switch" {
    // Full round-trip: write a real file, parseFile (saves path),
    // simulate set_system_dark (which calls applyAppearance + reapply),
    // and confirm the user's override survives.
    const path = "/tmp/matcha-test-config-roundtrip.cfg";
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const f = try cwd.createFile(io, path, .{});
    var write_buf: [256]u8 = undefined;
    var writer = f.writer(io, &write_buf);
    try writer.interface.writeAll("bg-color = #1a1a1a\n");
    try writer.interface.flush();
    f.close(io);
    defer cwd.deleteFile(io, path) catch {};

    var config = Config.defaults();
    defer config.deinit();
    config.allocator = std.testing.allocator;
    try parseFile(std.testing.allocator, &config, path);
    try std.testing.expectEqual(@as(u32, 0x1a1a1aFF), config.bg_color);

    // Simulate matcha_config_set_system_dark for a dark system.
    config.appearance = .dark;
    config.applyAppearance();
    config.appearance = .auto;
    try std.testing.expect(config.bg_color != 0x1a1a1aFF); // wiped by theme
    reapplyUserOverrides(&config);
    try std.testing.expectEqual(@as(u32, 0x1a1a1aFF), config.bg_color);
}

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

test "Parser: rejects tab-size 0 and keeps prior on parse failure" {
    var config = Config.defaults();
    defer config.deinit();
    config.font_size = 17;
    try parse(std.testing.allocator, &config,
        \\tab-size = 0
        \\font-size = wat
    );
    try std.testing.expectEqual(@as(u32, 4), config.tab_size); // unchanged
    try std.testing.expectEqual(@as(f64, 17), config.font_size); // unchanged
}

test "Parser: rejects non-finite and out-of-range font-size values" {
    var config = Config.defaults();
    defer config.deinit();
    config.font_size = 17;

    // "inf" and huge finite magnitudes are accepted by parseFloat but must
    // not reach font/atlas creation as infinite/NaN glyph metrics.
    try parse(std.testing.allocator, &config, "font-size = inf");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    try parse(std.testing.allocator, &config, "font-size = -inf");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    try parse(std.testing.allocator, &config, "font-size = nan");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    try parse(std.testing.allocator, &config, "font-size = 1e308");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    try parse(std.testing.allocator, &config, "font-size = 0");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    try parse(std.testing.allocator, &config, "font-size = 10000");
    try std.testing.expectEqual(@as(f64, 17), config.font_size);

    // A sane value still applies normally.
    try parse(std.testing.allocator, &config, "font-size = 22.5");
    try std.testing.expectEqual(@as(f64, 22.5), config.font_size);
}

test "Parser: 3-digit hex shorthand and case-insensitive bool" {
    var config = Config.defaults();
    defer config.deinit();
    try parse(std.testing.allocator, &config,
        \\bg-color = #f0a
        \\line-numbers = FALSE
        \\insert-spaces = yes
    );
    try std.testing.expectEqual(@as(u32, 0xFF00AAFF), config.bg_color);
    try std.testing.expect(!config.line_numbers);
    try std.testing.expect(config.insert_spaces);
}

test "Parser: previously-unwired color keys now apply" {
    var config = Config.defaults();
    defer config.deinit();
    try parse(std.testing.allocator, &config,
        \\gutter-bg-color = #112233
        \\chrome-fg-color = #aabbcc
        \\current-line-color = #fedcba
    );
    try std.testing.expectEqual(@as(u32, 0x112233FF), config.gutter_bg_color);
    try std.testing.expectEqual(@as(u32, 0xaabbccFF), config.chrome_fg_color);
    try std.testing.expectEqual(@as(u32, 0xfedcbaFF), config.current_line_color);
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
