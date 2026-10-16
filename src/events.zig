// Zigway: sistema de eventos.
//
// Modelo: `pollEvents()` drena o sistema nativo para uma fila interna;
// `nextEvent()` consome a fila. Eventos sao valores compactos (sem
// alocacao no hot path); a fila tem capacidade fixa e politica de
// overflow documentada.
//
// Politica de overflow (push em fila cheia):
//   1. Coalescing: pointer_move novo substitui o ultimo evento se ele
//      tambem for pointer_move da mesma janela.
//   2. Preservacao de criticos: eventos `close` nunca sao descartados
//      para dar lugar a nao-criticos; se a fila estiver cheia de
//      criticos, o novo evento e descartado e `dropped` incrementa.
//   3. Caso contrario, descarta-se o pointer_move mais antigo; se nao
//      houver, descarta-se o evento mais antigo nao-critico; por fim,
//      descarta-se o novo evento.
// Validade: eventos carregam apenas ids e escalares; nenhum dado
// emprestado de janela destruida.

const std = @import("std");
const types = @import("core/types.zig");
const input = @import("input.zig");

pub const WindowId = types.WindowId;
pub const Key = types.Key;
pub const MouseButton = types.MouseButton;
pub const Modifiers = types.Modifiers;

pub const CloseEvent = struct {
    window: WindowId,
};

pub const ResizeEvent = struct {
    window: WindowId,
    width: u32,
    height: u32,
};

pub const FocusEvent = struct {
    window: WindowId,
    focused: bool,
};

pub const KeyEvent = struct {
    window: ?WindowId,
    key: Key,
    modifiers: Modifiers,
    /// Repeticao automatica (quando o backend consegue informar).
    repeat: bool,
};

pub const PointerMoveEvent = struct {
    window: ?WindowId,
    x: i32,
    y: i32,
};

pub const PointerButtonEvent = struct {
    window: ?WindowId,
    button: MouseButton,
    pressed: bool,
    x: i32,
    y: i32,
    modifiers: Modifiers,
};

pub const ScrollEvent = struct {
    window: ?WindowId,
    /// Linhas (positivo: cima/direita, conforme eixo).
    dx: f32,
    dy: f32,
};

pub const Event = union(enum) {
    close: CloseEvent,
    resize: ResizeEvent,
    focus: FocusEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    pointer_move: PointerMoveEvent,
    pointer_button: PointerButtonEvent,
    scroll: ScrollEvent,

    /// Eventos que nunca podem ser silenciosamente descartados.
    pub fn isCritical(self: Event) bool {
        return switch (self) {
            .close => true,
            else => false,
        };
    }
};

/// Fila de eventos com capacidade fixa e sem alocacao apos o init.
pub const EventQueue = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    capacity: usize,
    dropped: u64,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventQueue {
        if (capacity == 0) return error.InvalidConfig;
        var events: std.ArrayList(Event) = .empty;
        try events.ensureTotalCapacity(allocator, capacity);
        return .{
            .events = events,
            .allocator = allocator,
            .capacity = capacity,
            .dropped = 0,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.events.deinit(self.allocator);
    }

    pub fn len(self: *const EventQueue) usize {
        return self.events.items.len;
    }

    pub fn push(self: *EventQueue, event: Event) void {
        // 1. Coalescing de pointer_move adjacente (mesma janela).
        if (event == .pointer_move and self.events.items.len > 0) {
            const last = &self.events.items[self.events.items.len - 1];
            if (last.* == .pointer_move and
                WindowId.eqlOpt(last.pointer_move.window, event.pointer_move.window))
            {
                last.* = event;
                return;
            }
        }

        if (self.events.items.len < self.capacity) {
            self.events.append(self.allocator, event) catch {
                self.dropped += 1;
                return;
            };
            return;
        }

        // 2/3. Fila cheia: tenta abrir espaco preservando criticos.
        if (self.makeRoom(event)) {
            self.events.append(self.allocator, event) catch {
                self.dropped += 1;
                return;
            };
        } else {
            self.dropped += 1;
        }
    }

    /// Abre espaco descartando um evento nao-critico. Retorna false se
    /// nada puder ser descartado (todos criticos e novo evento critico).
    fn makeRoom(self: *EventQueue, incoming: Event) bool {
        // Prefere descartar o pointer_move mais antigo.
        for (self.events.items, 0..) |ev, i| {
            if (ev == .pointer_move) {
                _ = self.events.orderedRemove(i);
                return true;
            }
        }
        // Novo evento nao-critico pode tomar o lugar do mais antigo
        // nao-critico.
        if (!incoming.isCritical()) {
            for (self.events.items, 0..) |ev, i| {
                if (!ev.isCritical()) {
                    _ = self.events.orderedRemove(i);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn next(self: *EventQueue) ?Event {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    pub fn clear(self: *EventQueue) void {
        self.events.clearRetainingCapacity();
    }
};

/// Enfileira o evento e atualiza o estado de input de forma consistente.
/// Ponto unico de entrada de eventos (backends e injecao sintetica).
pub fn dispatch(queue: *EventQueue, state: *input.InputState, event: Event) void {
    queue.push(event);
    state.apply(event);
}

test "queue preserves fifo order" {
    var q = try EventQueue.init(std.testing.allocator, 8);
    defer q.deinit();
    const id: WindowId = .{ .index = 0, .generation = 0 };
    q.push(.{ .resize = .{ .window = id, .width = 1, .height = 1 } });
    q.push(.{ .close = .{ .window = id } });
    const first = q.next().?;
    try std.testing.expect(first == .resize);
    const second = q.next().?;
    try std.testing.expect(second == .close);
    try std.testing.expect(q.next() == null);
}

test "queue coalesces adjacent pointer moves" {
    var q = try EventQueue.init(std.testing.allocator, 8);
    defer q.deinit();
    q.push(.{ .pointer_move = .{ .window = null, .x = 1, .y = 1 } });
    q.push(.{ .pointer_move = .{ .window = null, .x = 2, .y = 2 } });
    try std.testing.expectEqual(@as(usize, 1), q.len());
    const ev = q.next().?;
    try std.testing.expectEqual(@as(i32, 2), ev.pointer_move.x);
}

test "queue preserves close events on overflow" {
    var q = try EventQueue.init(std.testing.allocator, 2);
    defer q.deinit();
    const id: WindowId = .{ .index = 0, .generation = 0 };
    q.push(.{ .pointer_move = .{ .window = null, .x = 1, .y = 1 } });
    q.push(.{ .pointer_move = .{ .window = null, .x = 2, .y = 2 } });
    // Coalescing manteve len == 1; preenche com nao-criticos distintos.
    q.push(.{ .resize = .{ .window = id, .width = 3, .height = 3 } });
    try std.testing.expectEqual(@as(usize, 2), q.len());
    // Novo close deve expulsar um nao-critico, nunca se perder.
    q.push(.{ .close = .{ .window = id } });
    var saw_close = false;
    while (q.next()) |ev| {
        if (ev == .close) saw_close = true;
    }
    try std.testing.expect(saw_close);
    try std.testing.expectEqual(@as(u64, 0), q.dropped);
}

test "queue drops incoming when full of critical events" {
    var q = try EventQueue.init(std.testing.allocator, 1);
    defer q.deinit();
    const id: WindowId = .{ .index = 0, .generation = 0 };
    q.push(.{ .close = .{ .window = id } });
    q.push(.{ .close = .{ .window = id } });
    try std.testing.expectEqual(@as(u64, 1), q.dropped);
    try std.testing.expectEqual(@as(usize, 1), q.len());
}

test "zero capacity is rejected" {
    const res = EventQueue.init(std.testing.allocator, 0);
    try std.testing.expectError(error.InvalidConfig, res);
}
