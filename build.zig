const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const swift_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\SDK=$(xcrun --show-sdk-path)
        \\MACOS_VER=$(sw_vers -productVersion | cut -d. -f1,2)
        \\TARGET_ARCH=$(uname -m)
        \\APP=zig-out/Matcha.app/Contents/MacOS
        \\mkdir -p "$APP"
        \\cp macos/Matcha-Info.plist zig-out/Matcha.app/Contents/Info.plist
        \\mkdir -p zig-out/Matcha.app/Contents/Resources
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
        \\iconutil -c icns "$ICONSET" -o zig-out/Matcha.app/Contents/Resources/AppIcon.icns
        \\rm -rf "$ICONSET"
        \\swiftc \
        \\  -swift-version 5 \
        \\  -sdk "$SDK" \
        \\  -target "${TARGET_ARCH}-apple-macosx${MACOS_VER}" \
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
        \\  macos/Sources/Views/TabBarView.swift \
        \\  macos/Sources/Views/StatusBarView.swift \
        \\  macos/Sources/Renderer/MetalRenderer.swift \
        \\  macos/Sources/Input/KeyEventHandler.swift
        \\echo "Built zig-out/Matcha.app"
    });
    swift_cmd.step.dependOn(b.getInstallStep());
    app.dependOn(&swift_cmd.step);

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
