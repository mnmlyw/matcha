const std = @import("std");

const default_macos_min_version = std.SemanticVersion{
    .major = 14,
    .minor = 0,
    .patch = 0,
};

fn isMacosTarget(target: std.Build.ResolvedTarget) bool {
    if (target.query.os_tag) |tag| return tag == .macos;
    return target.result.os.tag == .macos;
}

fn normalizeTarget(b: *std.Build, requested: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (!isMacosTarget(requested) or requested.query.os_version_min != null) return requested;

    var query = requested.query;
    query.os_tag = .macos;
    query.os_version_min = .{ .semver = default_macos_min_version };
    query.os_version_max = null;
    return b.resolveTargetQuery(query);
}

fn macosMinVersion(target: std.Build.ResolvedTarget) std.SemanticVersion {
    if (target.query.os_version_min) |min| switch (min) {
        .semver => |version| return version,
        else => {},
    };
    return default_macos_min_version;
}

fn formatSemver(b: *std.Build, version: std.SemanticVersion) []const u8 {
    if (version.patch == 0) {
        return b.fmt("{d}.{d}", .{ version.major, version.minor });
    }
    return b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
}

fn swiftArchName(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => null,
    };
}

fn swiftOptimizeFlag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-Onone",
        .ReleaseSmall => "-Osize",
        .ReleaseSafe, .ReleaseFast => "-O",
    };
}

pub fn build(b: *std.Build) void {
    const requested_target = b.standardTargetOptions(.{});
    const target = normalizeTarget(b, requested_target);
    const optimize = b.standardOptimizeOption(.{});
    var sdk_path: ?[]const u8 = null;

    if (isMacosTarget(target) and b.sysroot == null) {
        if (std.zig.system.darwin.getSdk(b.allocator, &target.result)) |sdk| {
            sdk_path = sdk;
            b.sysroot = sdk;
        }
    }

    // ── Root module ────────────────────────────────────────────
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addIncludePath(b.path("include"));
    root_module.linkFramework("CoreText", .{});
    root_module.linkFramework("CoreFoundation", .{});
    root_module.linkFramework("CoreGraphics", .{});
    if (sdk_path) |sdk| {
        root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    }

    // ── Static library ─────────────────────────────────────────
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "matcha",
        .root_module = root_module,
    });

    b.installArtifact(lib);

    // Also install headers alongside the library
    b.installFile("include/matcha.h", "include/matcha.h");
    b.installFile("include/module.modulemap", "include/module.modulemap");

    // ── App build via swiftc ───────────────────────────────────
    const app = b.step("app", "Build Matcha.app via swiftc");
    if (!isMacosTarget(target)) {
        const fail_cmd = b.addSystemCommand(&.{
            "sh",                                                                "-c",
            "echo 'Matcha.app can only be built for macOS targets' >&2; exit 1",
        });
        app.dependOn(&fail_cmd.step);
    } else if (swiftArchName(target.result.cpu.arch)) |swift_arch| {
        const min_version = formatSemver(b, macosMinVersion(target));
        const info_plist = b.addWriteFiles().add("Matcha-Info.plist", b.fmt(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>CFBundleDevelopmentRegion</key>
            \\    <string>en</string>
            \\    <key>CFBundleExecutable</key>
            \\    <string>Matcha</string>
            \\    <key>CFBundleIdentifier</key>
            \\    <string>dev.matcha.Matcha</string>
            \\    <key>CFBundleInfoDictionaryVersion</key>
            \\    <string>6.0</string>
            \\    <key>CFBundleName</key>
            \\    <string>Matcha</string>
            \\    <key>CFBundlePackageType</key>
            \\    <string>APPL</string>
            \\    <key>CFBundleShortVersionString</key>
            \\    <string>0.1.0</string>
            \\    <key>CFBundleVersion</key>
            \\    <string>1</string>
            \\    <key>LSMinimumSystemVersion</key>
            \\    <string>{s}</string>
            \\    <key>CFBundleIconFile</key>
            \\    <string>AppIcon</string>
            \\    <key>CFBundleIconName</key>
            \\    <string>AppIcon</string>
            \\    <key>NSHighResolutionCapable</key>
            \\    <true/>
            \\    <key>NSPrincipalClass</key>
            \\    <string>NSApplication</string>
            \\    <key>CFBundleDocumentTypes</key>
            \\    <array>
            \\        <dict>
            \\            <key>CFBundleTypeName</key>
            \\            <string>All Files</string>
            \\            <key>CFBundleTypeRole</key>
            \\            <string>Editor</string>
            \\            <key>LSHandlerRank</key>
            \\            <string>Default</string>
            \\            <key>LSItemContentTypes</key>
            \\            <array>
            \\                <string>public.plain-text</string>
            \\                <string>public.source-code</string>
            \\                <string>public.script</string>
            \\                <string>public.shell-script</string>
            \\                <string>public.python-script</string>
            \\                <string>public.swift-source</string>
            \\                <string>public.c-source</string>
            \\                <string>public.c-header</string>
            \\                <string>public.c-plus-plus-source</string>
            \\                <string>public.objective-c-source</string>
            \\                <string>public.json</string>
            \\                <string>public.xml</string>
            \\                <string>public.yaml</string>
            \\                <string>public.text</string>
            \\                <string>public.data</string>
            \\                <string>public.content</string>
            \\                <string>public.item</string>
            \\                <string>com.netscape.javascript-source</string>
            \\                <string>com.apple.property-list</string>
            \\                <string>org.khronos.glsl.shader-source</string>
            \\                <string>org.lua.lua</string>
            \\            </array>
            \\        </dict>
            \\    </array>
            \\</dict>
            \\</plist>
        , .{min_version}));
        const swift_cmd = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -e
            \\SWIFT_TARGET=$1
            \\SWIFT_OPT=$2
            \\INFO_PLIST=$3
            \\SDK=$(xcrun --show-sdk-path)
            \\BUNDLE=zig-out/Matcha.app
            \\CONTENTS="$BUNDLE/Contents"
            \\APP="$CONTENTS/MacOS"
            \\STACK_PROBE_OBJ=
            \\rm -rf "$BUNDLE"
            \\mkdir -p "$APP"
            \\# Fix archive alignment for macOS linker (Zig 0.15 produces misaligned archives)
            \\ranlib -no_warning_for_no_symbols zig-out/lib/libmatcha.a 2>/dev/null || true
            \\cp "$INFO_PLIST" "$CONTENTS/Info.plist"
            \\mkdir -p "$CONTENTS/Resources"
            \\ICONSET=/tmp/matcha_AppIcon.iconset
            \\mkdir -p "$ICONSET"
            \\ICONS=macos/Assets.xcassets/AppIcon.appiconset
            \\cp "$ICONS/icon_16x16.png"     "$ICONSET/icon_16x16.png"
            \\cp "$ICONS/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
            \\cp "$ICONS/icon_32x32.png"     "$ICONSET/icon_32x32.png"
            \\cp "$ICONS/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
            \\cp "$ICONS/icon_128x128.png"   "$ICONSET/icon_128x128.png"
            \\cp "$ICONS/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
            \\cp "$ICONS/icon_256x256.png"   "$ICONSET/icon_256x256.png"
            \\cp "$ICONS/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
            \\cp "$ICONS/icon_512x512.png"   "$ICONSET/icon_512x512.png"
            \\cp "$ICONS/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
            \\iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
            \\rm -rf "$ICONSET"
            \\swiftc \
            \\  -swift-version 5 \
            \\  -sdk "$SDK" \
            \\  -target "$SWIFT_TARGET" \
            \\  "$SWIFT_OPT" \
            \\  -I include \
            \\  -L zig-out/lib \
            \\  -lmatcha \
            \\  -framework AppKit \
            \\  -framework SwiftUI \
            \\  -framework Metal \
            \\  -framework MetalKit \
            \\  -framework CoreText \
            \\  -framework CoreFoundation \
            \\  -framework CoreGraphics \
            \\  -Xlinker -lc \
            \\  -Xlinker -w \
            \\  -parse-as-library \
            \\  -o "$APP/Matcha" \
            \\  macos/Sources/App/MatchaApp.swift \
            \\  macos/Sources/App/TabManager.swift \
            \\  macos/Sources/Bridge/MatchaEditor.swift \
            \\  macos/Sources/Bridge/MatchaConfig.swift \
            \\  macos/Sources/Views/ContentView.swift \
            \\  macos/Sources/Views/EditorView.swift \
            \\  macos/Sources/Views/MetalEditorView.swift \
            \\  macos/Sources/Views/FindBarView.swift \
            \\  macos/Sources/Views/GoToLineView.swift \
            \\  macos/Sources/Views/CompletionPopupView.swift \
            \\  macos/Sources/Views/CommandPaletteView.swift \
            \\  macos/Sources/Views/FileFinderView.swift \
            \\  macos/Sources/Views/TabBarView.swift \
            \\  macos/Sources/Views/StatusBarView.swift \
            \\  macos/Sources/Renderer/MetalRenderer.swift \
            \\  macos/Sources/Input/KeyEventHandler.swift \
            \\  $STACK_PROBE_OBJ
            \\echo "Built zig-out/Matcha.app"
            ,
            "sh",
        });
        swift_cmd.addArg(b.fmt("{s}-apple-macosx{s}", .{ swift_arch, min_version }));
        swift_cmd.addArg(swiftOptimizeFlag(optimize));
        swift_cmd.addFileArg(info_plist);
        swift_cmd.step.dependOn(b.getInstallStep());
        app.dependOn(&swift_cmd.step);
    } else {
        const fail_cmd = b.addSystemCommand(&.{
            "sh",                                                                         "-c",
            "echo 'Matcha.app only supports arm64 and x86_64 Swift targets' >&2; exit 1",
        });
        app.dependOn(&fail_cmd.step);
    }

    // ── Unit tests ─────────────────────────────────────────────
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addIncludePath(b.path("include"));
    test_module.linkFramework("CoreText", .{});
    test_module.linkFramework("CoreFoundation", .{});
    test_module.linkFramework("CoreGraphics", .{});
    if (sdk_path) |sdk| {
        test_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    }

    const lib_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // ── Run step (convenience) ─────────────────────────────────
    const run = b.step("run", "Build and run Matcha.app");
    const run_cmd = b.addSystemCommand(&.{
        "open", "zig-out/Matcha.app",
    });
    run_cmd.step.dependOn(app);
    run.dependOn(&run_cmd.step);
}
