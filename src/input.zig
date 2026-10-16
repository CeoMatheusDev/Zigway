// Zigway: estado de input (teclado + ponteiro).
//
// O estado e atualizado centralmente via `apply()` a cada evento
// despachado (ver events.dispatch), de forma consistente com a fila.
// Nao depende de consultas globais ao SO.
//
// Nota: eventos de teclado sao fisicos/logicos (Key); entrada de texto
// Unicode/IME e Fase 3 e nao e confundida com Key.

const std = @import("std");
const types = @import("core/types.zig");
const events = @import("events.zig");

pub const Key = types.Key;
pub const MouseButton = types.MouseButton;
pub const Modifiers = types.Modifiers;
pub const WindowId = types.WindowId;

const KeySet = std.bit_set.Static(Key.count);

pub const InputState = struct {
    keys: KeySet = .empty,
    modifiers: Modifiers = .{},
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    pointer_window: ?WindowId = null,
    buttons: std.bit_set.Static(MouseButton.count) = .empty,

    pub fn isKeyDown(self: *const InputState, key: Key) bool {
        return self.keys.isSet(@backingInt(key));
    }

    pub fn isButtonDown(self: *const InputState, button: MouseButton) bool {
        return self.buttons.isSet(@backingInt(button));
    }

    pub fn apply(self: *InputState, event: events.Event) void {
        switch (event) {
            .key_down => |e| {
                self.keys.set(@backingInt(e.key));
                self.modifiers = e.modifiers;
            },
            .key_up => |e| {
                self.keys.unset(@backingInt(e.key));
                self.modifiers = e.modifiers;
            },
            .pointer_move => |e| {
                self.pointer_x = e.x;
                self.pointer_y = e.y;
                self.pointer_window = e.window;
            },
            .pointer_button => |e| {
                self.buttons.setValue(@backingInt(e.button), e.pressed);
                self.pointer_x = e.x;
                self.pointer_y = e.y;
                self.pointer_window = e.window;
                self.modifiers = e.modifiers;
            },
            .scroll => |e| {
                self.pointer_window = e.window;
            },
            .focus => {},
            .resize => {},
            .close => {},
        }
    }
};

test "key down/up transitions" {
    var state = InputState{};
    const down: events.Event = .{ .key_down = .{
        .window = null,
        .key = .a,
        .modifiers = .{ .shift = true },
        .repeat = false,
    } };
    state.apply(down);
    try std.testing.expect(state.isKeyDown(.a));
    try std.testing.expect(!state.isKeyDown(.b));
    try std.testing.expect(state.modifiers.shift);

    const up: events.Event = .{ .key_up = .{
        .window = null,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } };
    state.apply(up);
    try std.testing.expect(!state.isKeyDown(.a));
}

test "pointer state tracks moves and buttons" {
    var state = InputState{};
    state.apply(.{ .pointer_move = .{ .window = null, .x = 10, .y = 20 } });
    try std.testing.expectEqual(@as(i32, 10), state.pointer_x);
    try std.testing.expectEqual(@as(i32, 20), state.pointer_y);
    state.apply(.{ .pointer_button = .{
        .window = null,
        .button = .left,
        .pressed = true,
        .x = 10,
        .y = 20,
        .modifiers = .{},
    } });
    try std.testing.expect(state.isButtonDown(.left));
    try std.testing.expect(!state.isButtonDown(.right));
}

test "button release clears without disturbing other buttons" {
    var state = InputState{};
    const down_left: events.Event = .{ .pointer_button = .{
        .window = null,
        .button = .left,
        .pressed = true,
        .x = 0,
        .y = 0,
        .modifiers = .{},
    } };
    const down_right: events.Event = .{ .pointer_button = .{
        .window = null,
        .button = .right,
        .pressed = true,
        .x = 0,
        .y = 0,
        .modifiers = .{ .shift = true },
    } };
    state.apply(down_left);
    state.apply(down_right);
    try std.testing.expect(state.modifiers.shift);

    state.apply(.{ .pointer_button = .{
        .window = null,
        .button = .left,
        .pressed = false,
        .x = 5,
        .y = 6,
        .modifiers = .{},
    } });
    try std.testing.expect(!state.isButtonDown(.left));
    try std.testing.expect(state.isButtonDown(.right));
    try std.testing.expectEqual(@as(i32, 5), state.pointer_x);
    try std.testing.expect(!state.modifiers.shift);
}

test "scroll keeps buttons and tracks window" {
    var state = InputState{};
    state.apply(.{ .pointer_button = .{
        .window = null,
        .button = .middle,
        .pressed = true,
        .x = 1,
        .y = 1,
        .modifiers = .{},
    } });
    const id: WindowId = .{ .index = 7, .generation = 0 };
    state.apply(.{ .scroll = .{ .window = id, .dx = 0, .dy = 1 } });
    try std.testing.expect(state.isButtonDown(.middle));
    try std.testing.expect(state.pointer_window.?.eql(id));
}
