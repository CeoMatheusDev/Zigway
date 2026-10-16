// Zigway Platform: instancia coordenadora dos recursos nativos.
//
// Uma instancia possui N janelas (sem janela global). Ownership: a
// Platform detem fila de eventos, estado de input, registro de janelas e
// o backend nativo. `Window` (window.zig) e apenas um handle {id, *Platform}.
//
// Threading: afinidade com a thread criadora; todos os metodos devem ser
// chamados da mesma thread (X11 e Win32 exigem isso para a conexao).
// Cleanup: falhas parciais em init/create desalocam o que foi adquirido.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const caps = @import("../core/caps.zig");
const registry = @import("registry.zig");
const backend_mod = @import("backend.zig");
const events = @import("../events.zig");
const input = @import("../input.zig");
const window_mod = @import("../window.zig");
const NullBackend = @import("null_backend.zig").Backend;
const X11Backend = @import("../platform/x11/backend.zig").Backend;
const Win32Backend = @import("../platform/win32/backend.zig").Backend;

pub const BackendKind = types.BackendKind;
pub const ActiveBackend = types.ActiveBackend;
pub const Window = window_mod.Window;
pub const WindowConfig = window_mod.WindowConfig;
pub const Event = events.Event;

const has_x11 = builtin.os.tag == .linux;
const has_win32 = builtin.os.tag == .windows;

/// Uniao de backends compilaveis neste alvo. O despacho usa
/// `inline else` para existir apenas nas variantes presentes.
const BackendUnion = if (has_win32)
    union(enum) {
        null_backend: NullBackend,
        win32: Win32Backend,
    }
else if (has_x11)
    union(enum) {
        null_backend: NullBackend,
        x11: X11Backend,
    }
else
    union(enum) {
        null_backend: NullBackend,
    };

pub const Options = struct {
    backend: BackendKind = .auto,
    /// Capacidade da fila de eventos (> 0).
    event_queue_capacity: usize = 256,
};

pub const Platform = struct {
    allocator: std.mem.Allocator,
    active: ActiveBackend,
    events: events.EventQueue,
    input_state: input.InputState = .{},
    reg: registry.Registry = .{},
    backend: BackendUnion,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Platform {
        if (options.event_queue_capacity == 0) return error.InvalidConfig;
        const active = try backend_mod.resolve(options.backend);

        var queue = try events.EventQueue.init(allocator, options.event_queue_capacity);
        errdefer queue.deinit();

        const backend = try initBackend(allocator, active);
        return .{
            .allocator = allocator,
            .active = active,
            .events = queue,
            .reg = .{},
            .backend = backend,
        };
    }

    fn initBackend(allocator: std.mem.Allocator, active: ActiveBackend) !BackendUnion {
        if (active == .null_backend) {
            return .{ .null_backend = try NullBackend.init(allocator) };
        }
        if (comptime has_x11) {
            if (active == .x11) {
                return .{ .x11 = try X11Backend.init(allocator) };
            }
        }
        if (comptime has_win32) {
            if (active == .win32) {
                return .{ .win32 = try Win32Backend.init(allocator) };
            }
        }
        return error.UnsupportedBackend;
    }

    pub fn deinit(self: *Platform) void {
        // Destroi nativas restantes antes de fechar o backend.
        switch (self.backend) {
            inline else => |*b| {
                var i: u32 = 0;
                for (self.reg.slots.items) |slot| {
                    defer i += 1;
                    if (slot.occupied) b.destroyWindow(&self.reg, i);
                }
                b.deinit();
            },
        }
        self.reg.deinit(self.allocator);
        self.events.deinit();
    }

    pub fn backendKind(self: *const Platform) ActiveBackend {
        return self.active;
    }

    pub fn runtimeCaps(self: *const Platform) caps.RuntimeCaps {
        return caps.RuntimeCaps.forBackend(self.active);
    }

    pub fn createWindow(self: *Platform, cfg: WindowConfig) !Window {
        if (cfg.width == 0 or cfg.height == 0) return error.InvalidConfig;
        if (cfg.width > 16384 or cfg.height > 16384) return error.InvalidConfig;
        if (cfg.title.len > 1024) return error.InvalidConfig;

        const reserved = try self.reg.allocSlot(self.allocator);
        errdefer self.reg.freeSlot(reserved.id) catch {};

        const slot = &self.reg.slots.items[reserved.index];
        slot.width = cfg.width;
        slot.height = cfg.height;
        slot.visible = cfg.visible;

        switch (self.backend) {
            inline else => |*b| {
                b.createWindow(&self.reg, reserved.index, cfg) catch |err| {
                    return err;
                };
            },
        }

        return .{ .id = reserved.id, .platform = self };
    }

    pub fn destroyWindow(self: *Platform, id: types.WindowId) !void {
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| b.destroyWindow(&self.reg, index),
        }
        try self.reg.freeSlot(id);
        // Remove eventos pendentes da janela destruida (sem refs invalidas).
        self.pruneEvents(id);
    }

    /// Drena o sistema nativo para a fila interna. Infalivel: erros de
    /// transporte sao ignorados pelo backend apos o init.
    pub fn pollEvents(self: *Platform) void {
        switch (self.backend) {
            inline else => |*b| b.poll(&self.reg, &self.events, &self.input_state),
        }
    }

    pub fn nextEvent(self: *Platform) ?Event {
        return self.events.next();
    }

    /// Injeta um evento sintetico (testes/ferramentas). Atualiza o input
    /// como um evento nativo.
    pub fn injectEvent(self: *Platform, event: Event) void {
        events.dispatch(&self.events, &self.input_state, event);
    }

    pub fn isWindowAlive(self: *Platform, id: types.WindowId) bool {
        return self.reg.get(id) != null;
    }

    /// Invalido -> true (falha segura: loops de exemplo encerram).
    pub fn windowShouldClose(self: *Platform, id: types.WindowId) bool {
        const slot = self.reg.get(id) orelse return true;
        return slot.should_close;
    }

    pub fn requestWindowClose(self: *Platform, id: types.WindowId) void {
        const slot = self.reg.get(id) orelse return;
        slot.should_close = true;
    }

    pub fn windowSize(self: *Platform, id: types.WindowId) types.WindowSize {
        const slot = self.reg.get(id) orelse return .{ .width = 0, .height = 0 };
        return .{ .width = slot.width, .height = slot.height };
    }

    pub fn isWindowVisible(self: *Platform, id: types.WindowId) bool {
        const slot = self.reg.get(id) orelse return false;
        return slot.visible;
    }

    pub fn isWindowFocused(self: *Platform, id: types.WindowId) bool {
        const slot = self.reg.get(id) orelse return false;
        return slot.focused;
    }

    pub fn setWindowTitle(self: *Platform, id: types.WindowId, title: []const u8) !void {
        if (title.len > 1024) return error.InvalidConfig;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setTitle(&self.reg, index, title),
        }
    }

    pub fn setWindowSize(self: *Platform, id: types.WindowId, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidConfig;
        if (width > 16384 or height > 16384) return error.InvalidConfig;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        // Sem atualizacao otimista: o slot reflete o ultimo tamanho
        // CONFIRMADO (via evento nativo ou backend sincrono).
        switch (self.backend) {
            inline else => |*b| try b.setSize(&self.reg, index, width, height),
        }
    }

    pub fn setWindowVisible(self: *Platform, id: types.WindowId, visible: bool) !void {
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setVisible(&self.reg, index, visible),
        }
    }

    pub fn focusWindow(self: *Platform, id: types.WindowId) !void {
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.focusWindow(&self.reg, index),
        }
    }

    pub fn inputState(self: *const Platform) *const input.InputState {
        return &self.input_state;
    }

    fn pruneEvents(self: *Platform, id: types.WindowId) void {
        var kept: usize = 0;
        for (self.events.events.items) |ev| {
            if (ev.window()) |wid| {
                if (wid.eql(id)) continue;
            }
            self.events.events.items[kept] = ev;
            kept += 1;
        }
        self.events.events.items.len = kept;
    }
};

// --- Testes de lifecycle sobre o backend null (sem display) ---

test "platform init/deinit with null backend" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    try std.testing.expectEqual(ActiveBackend.null_backend, plat.backendKind());
}

test "zero queue capacity is rejected" {
    const res = Platform.init(std.testing.allocator, .{
        .backend = .null_backend,
        .event_queue_capacity = 0,
    });
    try std.testing.expectError(error.InvalidConfig, res);
}

test "window lifecycle: create, multi-window, destroy" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{ .width = 800, .height = 600, .title = "um" });
    defer w1.deinit();
    var w2 = try plat.createWindow(.{ .width = 640, .height = 480, .title = "dois" });
    defer w2.deinit();

    try std.testing.expect(!w1.windowId().eql(w2.windowId()));
    try std.testing.expect(!w1.shouldClose());
    try std.testing.expectEqual(@as(u32, 800), w1.size().width);

    w1.requestClose();
    try std.testing.expect(w1.shouldClose());
    try std.testing.expect(!w2.shouldClose());

    // Destroy invalida; eventos da janela sao podados.
    plat.injectEvent(.{ .close = .{ .window = w1.windowId() } });
    try plat.destroyWindow(w1.windowId());
    w1.id = types.WindowId.invalid;
    try std.testing.expect(plat.nextEvent() == null);
    try std.testing.expect(w2.isValid());
}

test "invalid configs are rejected" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    try std.testing.expectError(error.InvalidConfig, plat.createWindow(.{ .width = 0, .height = 10 }));
    try std.testing.expectError(error.InvalidConfig, plat.createWindow(.{ .width = 10, .height = 0 }));
    try std.testing.expectError(error.InvalidConfig, plat.createWindow(.{ .width = 99999, .height = 10 }));
    var long_buf: [1025]u8 = undefined;
    @memset(&long_buf, 'x');
    try std.testing.expectError(error.InvalidConfig, plat.createWindow(.{ .title = &long_buf }));
    try std.testing.expectError(error.InvalidWindow, plat.destroyWindow(.{ .index = 99, .generation = 0 }));
}

test "allocation failure releases partial resources" {
    // Queue com failing_allocator: nada e adquirido, nada vaza.
    try std.testing.expectError(error.OutOfMemory, Platform.init(
        std.testing.failing_allocator,
        .{ .backend = .null_backend },
    ));
}

test "input state follows injected events" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    var w = try plat.createWindow(.{});
    defer w.deinit();

    plat.injectEvent(.{ .key_down = .{
        .window = w.windowId(),
        .key = .escape,
        .modifiers = .{},
        .repeat = false,
    } });
    try std.testing.expect(plat.inputState().isKeyDown(.escape));

    // Evento enfileirado e consumivel.
    const ev = plat.nextEvent().?;
    try std.testing.expect(ev == .key_down);
    try std.testing.expect(plat.nextEvent() == null);
}

test "resize via backend updates slot and queues event" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    var w = try plat.createWindow(.{ .width = 100, .height = 100 });
    defer w.deinit();
    try w.setSize(200, 150);
    try std.testing.expectEqual(@as(u32, 200), w.size().width);
    try w.setTitle("novo titulo");
    try w.setVisible(false);
    try std.testing.expect(!plat.isWindowVisible(w.windowId()));
}

test "slot reuse bumps generation at platform level" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{});
    const old_id = w1.windowId();
    try plat.destroyWindow(old_id);
    w1.id = types.WindowId.invalid;

    var w2 = try plat.createWindow(.{});
    defer w2.deinit();
    // Mesmo indice, geracao maior; id antigo segue invalido.
    try std.testing.expectEqual(old_id.index, w2.windowId().index);
    try std.testing.expect(w2.windowId().generation > old_id.generation);
    try std.testing.expect(!plat.isWindowAlive(old_id));
    try std.testing.expectError(error.InvalidWindow, plat.destroyWindow(old_id));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowTitle(old_id, "x"));
}

test "destroy during dispatch is safe" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{});
    var w2 = try plat.createWindow(.{});
    defer w2.deinit();
    const id1 = w1.windowId();

    plat.injectEvent(.{ .close = .{ .window = id1 } });
    plat.injectEvent(.{ .close = .{ .window = w2.windowId() } });

    // Destroi w1 no meio do consumo; a fila restante segue valida.
    var saw_w2_close = false;
    while (plat.nextEvent()) |ev| {
        if (ev != .close) continue;
        if (ev.close.window.eql(id1)) {
            try plat.destroyWindow(id1);
            w1.id = types.WindowId.invalid;
        } else if (ev.close.window.eql(w2.windowId())) {
            saw_w2_close = true;
        }
    }
    try std.testing.expect(saw_w2_close);
    try std.testing.expect(!plat.isWindowAlive(id1));
}

test "mixed prune keeps other windows events" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{});
    var w2 = try plat.createWindow(.{});
    defer w2.deinit();
    const id1 = w1.windowId();

    plat.injectEvent(.{ .pointer_move = .{ .window = id1, .x = 1, .y = 1 } });
    plat.injectEvent(.{ .pointer_move = .{ .window = w2.windowId(), .x = 2, .y = 2 } });
    plat.injectEvent(.{ .key_down = .{
        .window = id1,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });

    try plat.destroyWindow(id1);
    w1.id = types.WindowId.invalid;

    // Resta apenas o evento de w2.
    const ev = plat.nextEvent().?;
    try std.testing.expect(ev == .pointer_move);
    try std.testing.expect(ev.pointer_move.window.?.eql(w2.windowId()));
    try std.testing.expect(plat.nextEvent() == null);
}

test "deinit destroys live windows without leaks" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    // Sem deinit individual: Platform.deinit deve limpar as nativas.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try plat.createWindow(.{});
    }
    plat.deinit();
    // testing.allocator falharia no leak ao fim do teste.
}

test "window copy and double deinit are safe" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    const id = w.windowId();
    var alias = w; // copia rasa: mesmo id, mesma platform
    w.deinit();
    alias.deinit(); // segundo deinit e ignorado
    try std.testing.expect(!plat.isWindowAlive(id));
    try std.testing.expect(!w.isValid());
}

test "alloc failure in createWindow leaves no slot" {
    // Uma alocacao para a fila no init; a seguinte (slot) falha.
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var plat = try Platform.init(fail.allocator(), .{ .backend = .null_backend });
    defer plat.deinit();
    try std.testing.expectError(error.OutOfMemory, plat.createWindow(.{}));
    try std.testing.expectEqual(@as(usize, 0), plat.reg.slots.items.len);
}

test "many windows stress create and destroy" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var alive: [16]Window = undefined;
    var kept: usize = 0;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        var w = try plat.createWindow(.{ .width = 100 + i, .height = 100 });
        if (i % 2 == 0) {
            w.deinit(); // destruicao imediata intercalada
        } else {
            alive[kept] = w;
            kept += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 16), kept);
    for (alive[0..kept]) |*w| {
        try std.testing.expect(w.isValid());
        w.deinit();
    }
    // Registro sem ocupados.
    for (plat.reg.slots.items) |slot| {
        try std.testing.expect(!slot.occupied);
    }
}

test "invalid ops on dead id return InvalidWindow" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    const id = w.windowId();
    w.deinit();

    try std.testing.expectError(error.InvalidWindow, plat.setWindowTitle(id, "x"));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowSize(id, 10, 10));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowVisible(id, true));
    try std.testing.expectError(error.InvalidWindow, plat.focusWindow(id));
}
