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
            .move => {},
            .display_change => {},
            .fullscreen => {},
            .maximized => {},
            .text_input => {},
            .composition_start => {},
            .composition_end => {},
            .scale_changed => {},
            .surrounding_delete => {},
            .raw_key => {},
            .close => {},
        }
    }

    /// Esquece qualquer referencia de ponteiro a `id`. Chamado ao
    /// destruir a janela: sem isso, `pointer_window` continuaria
    /// apontando para um id morto (estado de input invalido apos
    /// destroy). Teclas/botoes nao sao associados a janela e ficam
    /// intocados.
    pub fn forgetWindow(self: *InputState, id: WindowId) void {
        if (self.pointer_window) |pw| {
            if (pw.eql(id)) self.pointer_window = null;
        }
    }
};

/// Libera tudo que esta pressionado com eventos sinteticos (key_up e
/// pointer_button solto, modificadores zerados). Usado na perda de foco:
/// sem isso, teclas/botoes segurados durante Alt+Tab (cujo key_up o SO
/// nunca entrega) ficariam presos para sempre. A ordem (teclas, depois
/// botoes) nao carrega garantia causal; consumidores nao devem inferir
/// sequencia fisica desses eventos.
pub fn releaseAll(
    window: ?WindowId,
    queue: *events.EventQueue,
    state: *InputState,
) void {
    var i: usize = 0;
    while (i < Key.count) : (i += 1) {
        if (!state.keys.isSet(i)) continue;
        const key: Key = @fromBackingInt(@intCast(@as(u16, @intCast(i))));
        events.dispatch(queue, state, .{ .key_up = .{
            .window = window,
            .key = key,
            .modifiers = .{},
            .repeat = false,
        } });
    }
    var b: usize = 0;
    while (b < MouseButton.count) : (b += 1) {
        if (!state.buttons.isSet(b)) continue;
        const button: MouseButton = @fromBackingInt(@intCast(@as(u8, @intCast(b))));
        events.dispatch(queue, state, .{ .pointer_button = .{
            .window = window,
            .button = button,
            .pressed = false,
            .x = state.pointer_x,
            .y = state.pointer_y,
            .modifiers = .{},
        } });
    }
    state.modifiers = .{};
}

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

test "forgetWindow clears only the matching pointer window" {
    var state = InputState{};
    const a: WindowId = .{ .index = 1, .generation = 0 };
    const b: WindowId = .{ .index = 2, .generation = 0 };

    state.apply(.{ .pointer_move = .{ .window = a, .x = 1, .y = 1 } });
    // Janela diferente nao afeta o estado.
    state.forgetWindow(b);
    try std.testing.expect(state.pointer_window.?.eql(a));
    // A janela correspondente e esquecida.
    state.forgetWindow(a);
    try std.testing.expect(state.pointer_window == null);
}

test "releaseAll synthesizes releases and clears state" {
    var state = InputState{};
    var q = try events.EventQueue.init(std.testing.allocator, 16);
    defer q.deinit();
    const id: WindowId = .{ .index = 0, .generation = 0 };

    state.apply(.{ .key_down = .{
        .window = id,
        .key = .a,
        .modifiers = .{ .shift = true },
        .repeat = false,
    } });
    state.apply(.{ .key_down = .{
        .window = id,
        .key = .left_control,
        .modifiers = .{ .shift = true },
        .repeat = false,
    } });
    state.apply(.{ .pointer_button = .{
        .window = id,
        .button = .left,
        .pressed = true,
        .x = 3,
        .y = 4,
        .modifiers = .{},
    } });

    releaseAll(id, &q, &state);

    try std.testing.expect(!state.isKeyDown(.a));
    try std.testing.expect(!state.isKeyDown(.left_control));
    try std.testing.expect(!state.isButtonDown(.left));
    try std.testing.expect(!state.modifiers.shift);

    // 2 key_up + 1 button_up, todos associados a janela.
    var ups: usize = 0;
    while (q.next()) |ev| {
        switch (ev) {
            .key_up => |e| {
                try std.testing.expect(e.window.?.eql(id));
                try std.testing.expect(!e.repeat);
                ups += 1;
            },
            .pointer_button => |e| {
                try std.testing.expect(e.window.?.eql(id));
                try std.testing.expect(!e.pressed);
                ups += 1;
            },
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), ups);
}
