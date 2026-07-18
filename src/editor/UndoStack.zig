const std = @import("std");
const Allocator = std.mem.Allocator;
const PieceTable = @import("../buffer/PieceTable.zig").PieceTable;

pub const OpKind = enum {
    insert,
    delete,
};

pub const EditOp = struct {
    kind: OpKind,
    pos: u32,
    text: []const u8, // owned copy
};

pub const EditGroup = struct {
    ops: []EditOp, // owned
    /// Cursor position before the edit group (used by undo)
    cursor_line: u32,
    cursor_col: u32,
    /// Cursor position after the edit group (used by redo). For ops that
    /// move the cursor in a way unrelated to the last op's byte range
    /// (moveLineUp/Down, replaceAll, dedent), this is the only correct
    /// place to land on redo — the last-op-end heuristic produces the
    /// wrong column.
    post_cursor_line: u32 = 0,
    post_cursor_col: u32 = 0,
    has_post_cursor: bool = false,
};

const GroupList = std.ArrayListUnmanaged(EditGroup);
const OpList = std.ArrayListUnmanaged(EditOp);
const max_undo_groups: usize = 1000;
const max_undo_bytes: usize = 256 * 1024 * 1024;

pub const UndoStack = struct {
    allocator: Allocator,
    undo_stack: GroupList,
    redo_stack: GroupList,
    current_ops: OpList,
    current_cursor_line: u32,
    current_cursor_col: u32,
    /// Optional post-cursor for the in-progress group; consumed by commit().
    current_post_cursor_line: u32 = 0,
    current_post_cursor_col: u32 = 0,
    has_current_post_cursor: bool = false,
    /// Bytes retained by groups currently on undo_stack. Redo groups were
    /// already admitted through this cap and are accounted again only when
    /// moved back to undo_stack.
    undo_bytes: usize = 0,

    pub fn init(allocator: Allocator) UndoStack {
        return .{
            .allocator = allocator,
            .undo_stack = .empty,
            .redo_stack = .empty,
            .current_ops = .empty,
            .current_cursor_line = 0,
            .current_cursor_col = 0,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.undo_stack.items) |group| {
            self.freeGroup(group);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |group| {
            self.freeGroup(group);
        }
        self.redo_stack.deinit(self.allocator);
        for (self.current_ops.items) |op| {
            self.allocator.free(op.text);
        }
        self.current_ops.deinit(self.allocator);
    }

    pub fn freeGroup(self: *UndoStack, group: EditGroup) void {
        for (group.ops) |op| {
            self.allocator.free(op.text);
        }
        self.allocator.free(group.ops);
    }

    fn groupBytes(group: EditGroup) usize {
        var total: usize = group.ops.len * @sizeOf(EditOp);
        for (group.ops) |op| total +|= op.text.len;
        return total;
    }

    fn enforceUndoLimit(self: *UndoStack) void {
        while (self.undo_stack.items.len > max_undo_groups or self.undo_bytes > max_undo_bytes) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.undo_bytes -|= groupBytes(oldest);
            self.freeGroup(oldest);
        }
    }

    /// Record an operation for the current edit group.
    pub fn record(self: *UndoStack, kind: OpKind, pos: u32, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        try self.current_ops.append(self.allocator, .{
            .kind = kind,
            .pos = pos,
            .text = text_copy,
        });
    }

    /// Set cursor position for the current group (call before first edit).
    pub fn setCursorBefore(self: *UndoStack, line: u32, col: u32) void {
        if (self.current_ops.items.len == 0) {
            self.current_cursor_line = line;
            self.current_cursor_col = col;
        }
    }

    /// Record where the cursor should land if this group is later redone.
    /// Call this AFTER the cursor has been moved to its final post-edit
    /// position, BEFORE commit(). Only the most recent call wins; the
    /// flag is reset by commit().
    pub fn setCursorAfter(self: *UndoStack, line: u32, col: u32) void {
        self.current_post_cursor_line = line;
        self.current_post_cursor_col = col;
        self.has_current_post_cursor = true;
    }

    pub fn undoDepth(self: *const UndoStack) usize {
        return self.undo_stack.items.len;
    }

    pub fn redoDepth(self: *const UndoStack) usize {
        return self.redo_stack.items.len;
    }

    pub fn currentGroupEmpty(self: *const UndoStack) bool {
        return self.current_ops.items.len == 0;
    }

    /// Drop the current in-progress edit group.
    pub fn discardCurrentGroup(self: *UndoStack) void {
        for (self.current_ops.items) |op| {
            self.allocator.free(op.text);
        }
        self.current_ops.clearRetainingCapacity();
        self.has_current_post_cursor = false;
    }

    /// Remove a just-recorded operation whose corresponding buffer mutation
    /// failed before it was applied.
    pub fn discardLastCurrentOp(self: *UndoStack) void {
        const op = self.current_ops.pop() orelse return;
        self.allocator.free(op.text);
    }

    /// Best-effort rollback for a fully applied in-progress group. Operations
    /// are replayed in reverse, then always discarded so stale records can
    /// never merge into a later edit.
    pub fn rollbackCurrentGroup(self: *UndoStack, buffer: *PieceTable) void {
        var i = self.current_ops.items.len;
        while (i > 0) {
            i -= 1;
            const op = self.current_ops.items[i];
            switch (op.kind) {
                .insert => buffer.delete(op.pos, @intCast(op.text.len)) catch {},
                .delete => buffer.insert(op.pos, op.text) catch {},
            }
        }
        self.discardCurrentGroup();
    }

    /// Commit the current group of operations to the undo stack.
    /// Returns true if redo stack was cleared (branched history).
    ///
    /// On failure, ownership stays in current_ops so the Editor can replay the
    /// inverse operations and then discard the group. Production callers use
    /// Editor.commitUndoGroup for that rollback contract.
    pub fn commit(self: *UndoStack) !bool {
        if (self.current_ops.items.len == 0) return false;

        const ops = try self.allocator.dupe(EditOp, self.current_ops.items);
        self.undo_stack.append(self.allocator, .{
            .ops = ops,
            .cursor_line = self.current_cursor_line,
            .cursor_col = self.current_cursor_col,
            .post_cursor_line = self.current_post_cursor_line,
            .post_cursor_col = self.current_post_cursor_col,
            .has_post_cursor = self.has_current_post_cursor,
        }) catch |err| {
            // The dupe above is a shallow copy of the EditOp structs --
            // their `text` buffers are still exclusively owned by
            // current_ops (ownership only transfers on a successful
            // append), so freeing only the shallow outer copy here leaves the
            // current group intact for the Editor's rollback path.
            self.allocator.free(ops);
            return err;
        };
        self.current_ops.clearRetainingCapacity();
        self.has_current_post_cursor = false;
        self.undo_bytes +|= groupBytes(self.undo_stack.items[self.undo_stack.items.len - 1]);
        self.enforceUndoLimit();

        // Clear redo stack on new edit
        const had_redo = self.redo_stack.items.len > 0;
        for (self.redo_stack.items) |group| {
            self.freeGroup(group);
        }
        self.redo_stack.clearRetainingCapacity();
        return had_redo;
    }

    /// Pop the last undo group. Caller applies the inverse operations.
    pub fn popUndo(self: *UndoStack) ?EditGroup {
        if (self.undo_stack.items.len == 0) return null;
        const group = self.undo_stack.pop().?;
        self.undo_bytes -|= groupBytes(group);
        return group;
    }

    /// Push a group onto the redo stack.
    pub fn pushRedo(self: *UndoStack, group: EditGroup) !void {
        try self.redo_stack.append(self.allocator, group);
    }

    /// Pop the last redo group.
    pub fn popRedo(self: *UndoStack) ?EditGroup {
        if (self.redo_stack.items.len == 0) return null;
        return self.redo_stack.pop();
    }

    /// Push a group back onto the undo stack (after redo).
    pub fn pushUndo(self: *UndoStack, group: EditGroup) !void {
        try self.undo_stack.append(self.allocator, group);
        self.undo_bytes +|= groupBytes(group);
        self.enforceUndoLimit();
    }
};

test "UndoStack: history is capped by group count" {
    var stack = UndoStack.init(std.testing.allocator);
    defer stack.deinit();

    var i: usize = 0;
    while (i < max_undo_groups + 5) : (i += 1) {
        try stack.record(.insert, @intCast(i), "x");
        _ = try stack.commit();
    }
    try std.testing.expectEqual(max_undo_groups, stack.undoDepth());
    const oldest = stack.undo_stack.items[0];
    try std.testing.expectEqual(@as(u32, 5), oldest.ops[0].pos);
}
