const std = @import("std");
const Allocator = std.mem.Allocator;

/// Newline offset index for O(log n) line lookup.
/// For v0.1, line operations use linear scan in PieceTable.
/// This will be used for large file optimization.
pub const LineIndex = struct {
    allocator: Allocator,
    offsets: std.ArrayListUnmanaged(u32),

    pub fn init(allocator: Allocator) LineIndex {
        return .{
            .allocator = allocator,
            .offsets = .{},
        };
    }

    pub fn deinit(self: *LineIndex) void {
        self.offsets.deinit(self.allocator);
    }

    pub fn rebuild(self: *LineIndex, content_iter: anytype) !void {
        self.offsets.clearRetainingCapacity();
        var offset: u32 = 0;
        while (content_iter.next()) |byte| {
            if (byte == '\n') {
                try self.offsets.append(self.allocator, offset);
            }
            offset += 1;
        }
    }

    pub fn lineCount(self: *const LineIndex) u32 {
        return @intCast(self.offsets.items.len + 1);
    }
};
