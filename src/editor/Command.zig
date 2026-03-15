/// Command types for editor dispatch.
/// Used for keybinding mapping and command palette (deferred).
pub const Command = enum {
    // Movement
    move_left,
    move_right,
    move_up,
    move_down,
    move_line_start,
    move_line_end,
    move_start,
    move_end,
    move_page_up,
    move_page_down,
    move_word_left,
    move_word_right,

    // Selection
    select_left,
    select_right,
    select_up,
    select_down,
    select_line_start,
    select_line_end,
    select_all,
    select_word_left,
    select_word_right,

    // Editing
    delete_backward,
    delete_forward,
    newline,

    // Clipboard
    copy,
    cut,
    paste,

    // Undo
    undo,
    redo,

    // File
    save,
    save_as,
    open_file,
    new_file,
};
