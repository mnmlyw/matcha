const std = @import("std");

/// A simple demo showcasing syntax highlighting in Matcha.
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const name = "Matcha";
    const version: u32 = 1;
    const pi = 3.14159;

    // Print a greeting
    try stdout.print("Welcome to {s} v{d}!\n", .{ name, version });
    try stdout.print("Pi is approximately {d:.5}\n", .{pi});

    var sum: u64 = 0;
    for (0..10) |i| {
        sum += i * i;
    }

    if (sum > 100) {
        try stdout.print("Sum of squares: {d}\n", .{sum});
    } else {
        unreachable;
    }
}

const Color = enum {
    red,
    green,
    blue,

    fn isWarm(self: Color) bool {
        return self == .red;
    }
};

const Point = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    pub fn distance(self: Point, other: Point) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

test "point distance" {
    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 3, .y = 4 };
    try std.testing.expectEqual(@as(f32, 5.0), a.distance(b));
}
