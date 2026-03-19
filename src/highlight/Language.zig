const std = @import("std");

pub const Language = enum {
    none,
    zig,
    swift,
    c,
    python,
    javascript,
    rust,
    go,
    shell,
    markdown,
    json,
    toml,
    lua,
    yaml,

    pub fn detectFromFilename(name: []const u8) Language {
        const ext = extensionOf(name) orelse return .none;
        const map = .{
            .{ ".zig", .zig },
            .{ ".zon", .zig },
            .{ ".swift", .swift },
            .{ ".c", .c },
            .{ ".h", .c },
            .{ ".cpp", .c },
            .{ ".cc", .c },
            .{ ".cxx", .c },
            .{ ".hpp", .c },
            .{ ".py", .python },
            .{ ".pyw", .python },
            .{ ".js", .javascript },
            .{ ".mjs", .javascript },
            .{ ".cjs", .javascript },
            .{ ".jsx", .javascript },
            .{ ".ts", .javascript },
            .{ ".tsx", .javascript },
            .{ ".rs", .rust },
            .{ ".go", .go },
            .{ ".sh", .shell },
            .{ ".bash", .shell },
            .{ ".zsh", .shell },
            .{ ".fish", .shell },
            .{ ".md", .markdown },
            .{ ".markdown", .markdown },
            .{ ".json", .json },
            .{ ".toml", .toml },
            .{ ".lua", .lua },
            .{ ".yaml", .yaml },
            .{ ".yml", .yaml },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, ext, entry[0])) return entry[1];
        }
        return .none;
    }

    pub fn lineCommentPrefix(self: Language) ?[]const u8 {
        return switch (self) {
            .zig, .swift, .c, .javascript, .rust, .go => "//",
            .lua => "--",
            .python, .shell, .toml, .yaml => "#",
            else => null,
        };
    }

    fn extensionOf(name: []const u8) ?[]const u8 {
        // Find the last '/' or '\' to get the basename
        var basename = name;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |pos| {
            basename = name[pos + 1 ..];
        }
        if (std.mem.lastIndexOfScalar(u8, basename, '\\')) |pos| {
            basename = basename[pos + 1 ..];
        }
        // Find the last '.' in basename
        const dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
        return basename[dot..];
    }
};

// ── Tests ──────────────────────────────────────────────────────
test "Language: detect from filename" {
    const L = Language;
    try std.testing.expectEqual(L.zig, L.detectFromFilename("main.zig"));
    try std.testing.expectEqual(L.zig, L.detectFromFilename("build.zon"));
    try std.testing.expectEqual(L.swift, L.detectFromFilename("AppDelegate.swift"));
    try std.testing.expectEqual(L.c, L.detectFromFilename("buffer.c"));
    try std.testing.expectEqual(L.c, L.detectFromFilename("buffer.h"));
    try std.testing.expectEqual(L.c, L.detectFromFilename("main.cpp"));
    try std.testing.expectEqual(L.python, L.detectFromFilename("script.py"));
    try std.testing.expectEqual(L.javascript, L.detectFromFilename("index.js"));
    try std.testing.expectEqual(L.javascript, L.detectFromFilename("app.ts"));
    try std.testing.expectEqual(L.javascript, L.detectFromFilename("component.tsx"));
    try std.testing.expectEqual(L.rust, L.detectFromFilename("lib.rs"));
    try std.testing.expectEqual(L.go, L.detectFromFilename("main.go"));
    try std.testing.expectEqual(L.shell, L.detectFromFilename("deploy.sh"));
    try std.testing.expectEqual(L.markdown, L.detectFromFilename("README.md"));
    try std.testing.expectEqual(L.json, L.detectFromFilename("package.json"));
    try std.testing.expectEqual(L.toml, L.detectFromFilename("Cargo.toml"));
    try std.testing.expectEqual(L.yaml, L.detectFromFilename("config.yml"));
    try std.testing.expectEqual(L.yaml, L.detectFromFilename("config.yaml"));
    try std.testing.expectEqual(L.lua, L.detectFromFilename("init.lua"));
    try std.testing.expectEqual(L.none, L.detectFromFilename("Makefile"));
    try std.testing.expectEqual(L.none, L.detectFromFilename("README"));
}

test "Language: detect with path" {
    try std.testing.expectEqual(Language.zig, Language.detectFromFilename("/home/user/project/src/main.zig"));
    try std.testing.expectEqual(Language.python, Language.detectFromFilename("../scripts/run.py"));
}

test "Language: line comment prefixes" {
    try std.testing.expectEqualStrings("//", Language.zig.lineCommentPrefix().?);
    try std.testing.expectEqualStrings("//", Language.swift.lineCommentPrefix().?);
    try std.testing.expectEqualStrings("#", Language.python.lineCommentPrefix().?);
    try std.testing.expectEqualStrings("#", Language.yaml.lineCommentPrefix().?);
    try std.testing.expect(Language.markdown.lineCommentPrefix() == null);
    try std.testing.expectEqualStrings("--", Language.lua.lineCommentPrefix().?);
    try std.testing.expect(Language.none.lineCommentPrefix() == null);
}
