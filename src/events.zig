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

/// Nova posicao confirmada da origem da area de cliente, em coordenadas
/// de tela do backend.
pub const MoveEvent = struct {
    window: WindowId,
    x: i32,
    y: i32,
};

/// Mudanca na configuracao de monitores/display. Sem payload: o consumidor
/// deve reconsultar `Platform.displays()` para obter o novo snapshot.
pub const DisplayChangeEvent = struct {};

pub const FocusEvent = struct {
    window: WindowId,
    focused: bool,
};

/// Estado de fullscreen confirmado para a janela.
pub const FullscreenEvent = struct {
    window: WindowId,
    fullscreen: bool,
};

/// Estado de maximizacao confirmado para a janela.
pub const MaximizedEvent = struct {
    window: WindowId,
    maximized: bool,
};

/// Texto digitado/composto (entrada Unicode), separado de `Key`.
///
/// Um evento por codepoint Unicode: um IME que confirma uma frase
/// produz varios eventos, na ordem do texto.
pub const TextInputEvent = struct {
    window: WindowId,
    /// Codepoint Unicode (U+0000..U+10FFFF).
    codepoint: u32,
};

/// Inicio de uma composicao de texto (IME): o texto que o usuario esta
/// escrevendo aparece em `composition_update` ate a confirmacao.
pub const CompositionStartEvent = struct {
    window: WindowId,
};

/// Fim de uma composicao: o texto foi confirmado (`text_input`) ou
/// cancelado. O texto em composicao e consultado com
/// `Platform.compositionText`.
pub const CompositionEndEvent = struct {
    window: WindowId,
};

/// Tecla em nivel de hardware ("input bruto"), separada de `Key`.
///
/// Permite distinguir teclas fisicas que o `Key` agrupa (Shift
/// esquerdo/direito) e usar a tecla independentemente do layout.
pub const RawKeyEvent = struct {
    window: WindowId,
    /// Scancode da tecla fisica: keycode do X11 ou scan code do Win32.
    scancode: u32,
    pressed: bool,
    modifiers: Modifiers,
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
    move: MoveEvent,
    display_change: DisplayChangeEvent,
    fullscreen: FullscreenEvent,
    maximized: MaximizedEvent,
    text_input: TextInputEvent,
    composition_start: CompositionStartEvent,
    composition_end: CompositionEndEvent,
    raw_key: RawKeyEvent,
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

    /// Janela associada ao evento, quando houver. Usado para podar
    /// eventos de janelas destruidas sem deixar referencias invalidas.
    pub fn window(self: Event) ?WindowId {
        return switch (self) {
            .close => |e| e.window,
            .resize => |e| e.window,
            .move => |e| e.window,
            .display_change => null,
            .fullscreen => |e| e.window,
            .maximized => |e| e.window,
            .text_input => |e| e.window,
            .composition_start => |e| e.window,
            .composition_end => |e| e.window,
            .raw_key => |e| e.window,
            .focus => |e| e.window,
            .key_down => |e| e.window,
            .key_up => |e| e.window,
            .pointer_move => |e| e.window,
            .pointer_button => |e| e.window,
            .scroll => |e| e.window,
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
        // display_change tambem e coalescido: uma reconfiguracao pode gerar
        // varios eventos RandR/WM seguidos; um unico aviso basta.
        if (event == .display_change and self.events.items.len > 0) {
            if (self.events.items[self.events.items.len - 1] == .display_change) return;
        }
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

test "queue coalesces adjacent display changes" {
    var q = try EventQueue.init(std.testing.allocator, 8);
    defer q.deinit();
    q.push(.{ .display_change = .{} });
    q.push(.{ .display_change = .{} });
    try std.testing.expectEqual(@as(usize, 1), q.len());
    // Uma janela entre os avisos separa o coalescing (FIFO preservado).
    const id: WindowId = .{ .index = 0, .generation = 0 };
    q.push(.{ .resize = .{ .window = id, .width = 1, .height = 1 } });
    q.push(.{ .display_change = .{} });
    try std.testing.expectEqual(@as(usize, 3), q.len());
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

test "event window accessor covers all variants" {
    const id: WindowId = .{ .index = 3, .generation = 1 };
    const cases = [_]Event{
        .{ .close = .{ .window = id } },
        .{ .resize = .{ .window = id, .width = 1, .height = 1 } },
        .{ .move = .{ .window = id, .x = 1, .y = 2 } },
        .{ .display_change = .{} },
        .{ .fullscreen = .{ .window = id, .fullscreen = true } },
        .{ .maximized = .{ .window = id, .maximized = true } },
        .{ .text_input = .{ .window = id, .codepoint = 'a' } },
        .{ .composition_start = .{ .window = id } },
        .{ .composition_end = .{ .window = id } },
        .{ .raw_key = .{ .window = id, .scancode = 30, .pressed = true, .modifiers = .{} } },
        .{ .focus = .{ .window = id, .focused = true } },
        .{ .key_down = .{ .window = id, .key = .a, .modifiers = .{}, .repeat = false } },
        .{ .key_up = .{ .window = id, .key = .a, .modifiers = .{}, .repeat = false } },
        .{ .pointer_move = .{ .window = id, .x = 0, .y = 0 } },
        .{ .pointer_button = .{
            .window = id,
            .button = .left,
            .pressed = true,
            .x = 0,
            .y = 0,
            .modifiers = .{},
        } },
        .{ .scroll = .{ .window = id, .dx = 0, .dy = 0 } },
    };
    for (cases) |ev| {
        if (ev == .display_change) {
            try std.testing.expect(ev.window() == null);
            continue;
        }
        try std.testing.expect(ev.window().?.eql(id));
    }
    const floating: Event = .{ .key_down = .{
        .window = null,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } };
    try std.testing.expect(floating.window() == null);
}

test "overflow drops oldest non-critical first" {
    var q = try EventQueue.init(std.testing.allocator, 3);
    defer q.deinit();
    const id: WindowId = .{ .index = 0, .generation = 0 };
    // Sem moves para coalescer: resize distintos preenchem a fila.
    q.push(.{ .resize = .{ .window = id, .width = 1, .height = 1 } });
    q.push(.{ .resize = .{ .window = id, .width = 2, .height = 2 } });
    q.push(.{ .resize = .{ .window = id, .width = 3, .height = 3 } });
    // Novo nao-critico expulsa o mais antigo nao-critico.
    q.push(.{ .resize = .{ .window = id, .width = 4, .height = 4 } });
    try std.testing.expectEqual(@as(u64, 0), q.dropped);
    const first = q.next().?;
    try std.testing.expectEqual(@as(u32, 2), first.resize.width);
}

test "dispatch keeps input state consistent even when event is dropped" {
    // Garantia: o estado de input e atualizado em `dispatch`
    // independentemente da fila. Um evento descartado por overflow
    // ainda reflete em `isKeyDown`/`isButtonDown`, evitando estado
    // divergente entre "o que a fila entregou" e "o que esta pressionado".
    var q = try EventQueue.init(std.testing.allocator, 1);
    defer q.deinit();
    var state = input.InputState{};
    const id: WindowId = .{ .index = 0, .generation = 0 };

    // Fila cheia de um critico: o proximo nao-critico sera descartado.
    dispatch(&q, &state, .{ .close = .{ .window = id } });
    dispatch(&q, &state, .{ .key_down = .{
        .window = id,
        .key = .a,
        .modifiers = .{ .shift = true },
        .repeat = false,
    } });
    try std.testing.expectEqual(@as(u64, 1), q.dropped);
    try std.testing.expectEqual(@as(usize, 1), q.len());

    // O evento nao entrou na fila, mas o estado reflete o key_down.
    try std.testing.expect(state.isKeyDown(.a));
    try std.testing.expect(state.modifiers.shift);
}
