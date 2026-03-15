const std = @import("std");
const Allocator = std.mem.Allocator;

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
    /// Cursor position before the edit group
    cursor_line: u32,
    cursor_col: u32,
};

const GroupList = std.ArrayListUnmanaged(EditGroup);
const OpList = std.ArrayListUnmanaged(EditOp);

pub const UndoStack = struct {
    allocator: Allocator,
    undo_stack: GroupList,
    redo_stack: GroupList,
    current_ops: OpList,
    current_cursor_line: u32,
    current_cursor_col: u32,

    pub fn init(allocator: Allocator) UndoStack {
        return .{
            .allocator = allocator,
            .undo_stack = .{},
            .redo_stack = .{},
            .current_ops = .{},
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

    fn freeGroup(self: *UndoStack, group: EditGroup) void {
        for (group.ops) |op| {
            self.allocator.free(op.text);
        }
        self.allocator.free(group.ops);
    }

    /// Record an operation for the current edit group.
    pub fn record(self: *UndoStack, kind: OpKind, pos: u32, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
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

    /// Commit the current group of operations to the undo stack.
    pub fn commit(self: *UndoStack) !void {
        if (self.current_ops.items.len == 0) return;

        const ops = try self.allocator.dupe(EditOp, self.current_ops.items);
        try self.undo_stack.append(self.allocator, .{
            .ops = ops,
            .cursor_line = self.current_cursor_line,
            .cursor_col = self.current_cursor_col,
        });
        self.current_ops.clearRetainingCapacity();

        // Clear redo stack on new edit
        for (self.redo_stack.items) |group| {
            self.freeGroup(group);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    /// Pop the last undo group. Caller applies the inverse operations.
    pub fn popUndo(self: *UndoStack) ?EditGroup {
        if (self.undo_stack.items.len == 0) return null;
        return self.undo_stack.pop();
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
    }
};
