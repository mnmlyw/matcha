/// CoreText C bindings for font discovery and metrics from Zig.
/// Used by the glyph atlas to rasterize glyphs.
///
/// For v0.1, glyph rasterization is done on the Swift side using CoreText.
/// This module will be expanded when Zig-side rasterization is needed.
const std = @import("std");
const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
});

pub const CTFontRef = c.CTFontRef;
pub const CGGlyph = c.CGGlyph;

pub fn createFont(name: []const u8, size: f64) ?CTFontRef {
    const cf_name = c.CFStringCreateWithBytes(
        null,
        name.ptr,
        @intCast(name.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse return null;
    defer c.CFRelease(cf_name);

    return c.CTFontCreateWithName(cf_name, size, null);
}

pub fn releaseFont(font: CTFontRef) void {
    c.CFRelease(font);
}
