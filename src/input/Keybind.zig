const std = @import("std");
const Key = @import("Key.zig");

pub const Action = enum {
    save,
    open,
    undo,
    redo,
    copy,
    cut,
    paste,
    select_all,
    move_line_start,
    move_line_end,
    move_start,
    move_end,
    delete_line,
    new_file,
};

pub const Keybind = struct {
    keycode: u16,
    modifiers: u32,
    action: Action,
};

/// Default keybindings (Cmd+key for macOS).
pub const default_bindings = [_]Keybind{
    .{ .keycode = 1, .modifiers = 8, .action = .save }, // Cmd+S
    .{ .keycode = 31, .modifiers = 8, .action = .open }, // Cmd+O
    .{ .keycode = 6, .modifiers = 8, .action = .undo }, // Cmd+Z
    .{ .keycode = 6, .modifiers = 9, .action = .redo }, // Cmd+Shift+Z
    .{ .keycode = 8, .modifiers = 8, .action = .copy }, // Cmd+C
    .{ .keycode = 7, .modifiers = 8, .action = .cut }, // Cmd+X
    .{ .keycode = 9, .modifiers = 8, .action = .paste }, // Cmd+V
    .{ .keycode = 0, .modifiers = 8, .action = .select_all }, // Cmd+A
};

/// Match a key event against bindings. Returns the action if matched.
pub fn matchBinding(keycode: u16, modifiers: u32) ?Action {
    for (&default_bindings) |binding| {
        if (binding.keycode == keycode and binding.modifiers == modifiers) {
            return binding.action;
        }
    }
    return null;
}
