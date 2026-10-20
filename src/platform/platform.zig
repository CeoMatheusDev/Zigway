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
const WaylandBackend = @import("../platform/wayland/backend.zig").Backend;

pub const BackendKind = types.BackendKind;
pub const ActiveBackend = types.ActiveBackend;
pub const Window = window_mod.Window;
pub const WindowConfig = window_mod.WindowConfig;
pub const Event = events.Event;

const has_x11 = builtin.os.tag == .linux;
const has_win32 = builtin.os.tag == .windows;
const has_wayland = builtin.os.tag == .linux;

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
        wayland: WaylandBackend,
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
    /// Pós-deinit: todas as operações tornam-se falhas seguras
    /// (erros ou no-ops) em vez de use-after-free. Ownership da
    /// instancia e unico e intransferivel: nao copiar Platform.
    closed: bool = false,

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
            if (active == .wayland) {
                return .{ .wayland = try WaylandBackend.init(allocator) };
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
        // Idempotente: segundo deinit e no-op (nunca double-free ou
        // duplo fechamento nativo).
        if (self.closed) return;
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
        self.closed = true;
    }

    pub fn backendKind(self: *const Platform) ActiveBackend {
        return self.active;
    }

    pub fn runtimeCaps(self: *const Platform) caps.RuntimeCaps {
        return caps.RuntimeCaps.forBackend(self.active);
    }

    /// Snapshot dos monitores/display outputs ativos. O chamador libera a
    /// slice com o mesmo alocador. Plataforma fechada retorna lista vazia.
    /// O backend null nao inventa monitores (lista vazia).
    pub fn displays(
        self: *const Platform,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        if (self.closed) return allocator.alloc(types.DisplayInfo, 0);
        return switch (self.backend) {
            inline else => |*b| b.displays(allocator),
        };
    }

    /// Modos de video oferecidos por um display. O chamador libera a slice
    /// com o mesmo alocador. Lista vazia quando o backend nao expoe modos
    /// (sem RandR 1.5+ no X11, Win32 e null).
    pub fn displayModes(
        self: *const Platform,
        allocator: std.mem.Allocator,
        id: types.DisplayId,
    ) ![]types.DisplayMode {
        if (self.closed) return allocator.alloc(types.DisplayMode, 0);
        return switch (self.backend) {
            inline else => |*b| b.displayModes(allocator, id),
        };
    }

    /// Aplica um modo de video em um display. O `DisplayId` deve vir do
    /// snapshot atual de `displays()` e o `DisplayModeId` da lista de
    /// `displayModes` do mesmo display.
    pub fn setDisplayMode(
        self: *Platform,
        id: types.DisplayId,
        mode: types.DisplayModeId,
    ) !void {
        if (self.closed) return error.PlatformClosed;
        if (!id.isValid()) return error.InvalidDisplay;
        if (!mode.isValid()) return error.InvalidDisplayMode;
        switch (self.backend) {
            inline else => |*b| try b.setDisplayMode(id, mode),
        }
    }

    /// Escala de exibicao de uma janela (1/1 = 100%).
    pub fn windowScale(self: *const Platform, id: types.WindowId) types.Scale {
        if (self.closed) return .identity;
        return switch (self.backend) {
            inline else => |*b| b.windowScale(&self.reg, id),
        };
    }

    /// Escala de exibicao de uma janela, tambem registrada no slot (para
    /// que o estado do registro reflita a escala corrente).
    pub fn windowScaleAndSync(self: *Platform, id: types.WindowId) types.Scale {
        const scale = self.windowScale(id);
        if (self.reg.get(id)) |slot| slot.scale = scale;
        return scale;
    }

    /// Tamanho fisico do buffer da janela (pixels da tela).
    pub fn windowBufferSize(self: *const Platform, id: types.WindowId) types.WindowSize {
        if (self.closed) return .{ .width = 0, .height = 0 };
        return switch (self.backend) {
            inline else => |*b| b.windowBufferSize(&self.reg, id),
        };
    }

    /// Escala de exibicao de um display. No Wayland vem do output (inteira
    /// ou fracionaria); no Win32 do DPI do monitor; no X11 e uma
    /// aproximacao pelo DPI da tela (o X11 nao tem escala por monitor).
    pub fn displayScale(self: *const Platform, id: types.DisplayId) types.Scale {
        if (self.closed) return .identity;
        return switch (self.backend) {
            inline else => |*b| b.displayScale(id),
        };
    }

    /// Capacidades do backend ativo. Permite a aplicacao decidir o que
    /// usar sem identificar o backend (e sem tentar uma operacao que o
    /// protocolo nao suporta).
    pub fn capabilities(self: *const Platform) types.Capabilities {
        if (self.closed) return .{};
        return switch (self.backend) {
            inline else => |*b| b.capabilities(),
        };
    }

    /// Informa ao IME o texto ao redor do cursor da janela.
    ///
    /// `text` e o contexto (UTF-8) e `cursor` o deslocamento do cursor
    /// dentro dele (em bytes). A plataforma nao guarda o texto: apenas o
    /// repassa ao compositor. Quem remove texto em resposta a um
    /// `delete_surrounding_text` e a aplicacao (evento
    /// `surrounding_delete`).
    pub fn setWindowSurroundingText(
        self: *Platform,
        id: types.WindowId,
        text: []const u8,
        cursor: u32,
    ) !void {
        if (self.closed) return error.PlatformClosed;
        switch (self.backend) {
            inline else => |*b| try b.setSurroundingText(&self.reg, id, text, cursor),
        }
    }

    /// Texto em composicao (IME) da janela: o preedit atual, em UTF-8.
    /// O buffer pertence a plataforma e vale ate o proximo evento de
    /// composicao. `null` quando nao ha composicao em andamento.
    pub fn compositionText(self: *const Platform, id: types.WindowId) ?[]const u8 {
        if (self.closed) return null;
        return switch (self.backend) {
            inline else => |*b| b.compositionText(&self.reg, id),
        };
    }

    /// Capacidades do seat (dispositivos de entrada) do compositor.
    /// `null` quando o backend nao modela um seat (X11/Win32/null) ou
    /// quando o compositor nao expoe seat.
    pub fn seatCapabilities(self: *const Platform) ?types.SeatCapabilities {
        if (self.closed) return null;
        return switch (self.backend) {
            inline else => |*b| b.seatCapabilities(),
        };
    }

    /// Define o texto (UTF-8) da area de transferencia. O conteudo e
    /// copiado pela plataforma (o chamador pode liberar o buffer).
    pub fn setClipboardText(self: *Platform, text: []const u8) !void {
        if (self.closed) return error.PlatformClosed;
        switch (self.backend) {
            inline else => |*b| try b.setClipboardText(text),
        }
    }

    /// Texto (UTF-8) da area de transferencia. `null` quando vazia, sem
    /// texto ou quando o owner nao responde a tempo. O chamador libera a
    /// slice com o mesmo alocador.
    ///
    /// No X11 a leitura e sincrona e bloqueia ate o timeout do owner da
    /// selecao; eventos do app nesse intervalo vao para a fila normal.
    pub fn clipboardText(
        self: *Platform,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        if (self.closed) return null;
        return switch (self.backend) {
            inline else => |*b| b.clipboardText(
                &self.reg,
                &self.events,
                &self.input_state,
                allocator,
            ),
        };
    }

    pub fn createWindow(self: *Platform, cfg: WindowConfig) !Window {
        if (self.closed) return error.PlatformClosed;
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
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| b.destroyWindow(&self.reg, index),
        }
        try self.reg.freeSlot(id);
        // Remove eventos pendentes da janela destruida (sem refs invalidas).
        self.pruneEvents(id);
        // Nao deixa o estado de input apontando para a janela morta.
        self.input_state.forgetWindow(id);
    }

    /// Drena o sistema nativo para a fila interna. Infalivel: erros de
    /// transporte sao ignorados pelo backend apos o init. No-op apos deinit.
    pub fn pollEvents(self: *Platform) void {
        if (self.closed) return;
        switch (self.backend) {
            inline else => |*b| b.poll(&self.reg, &self.events, &self.input_state),
        }
    }

    /// Espera por eventos ate `timeout_ms` (ms) e os despacha.
    ///
    /// - `timeout_ms < 0`: espera indefinida (ate `wakeup` ou evento).
    /// - `timeout_ms == 0`: nao bloqueia (equivale a `pollEvents`).
    ///
    /// Devolve quantos eventos foram despachados nesta chamada. O
    /// timeout e um piso: o backend pode acordar antes (evento) ou
    /// depois (arredondamento do SO). Nao ha busy-wait: o backend
    /// dorme no descritor da conexao nativa.
    ///
    /// Esta chamada bloqueia a thread: use a mesma thread que criou a
    /// plataforma (as conexoes X11/Wayland/Win32 tem afinidade de
    /// thread).
    pub fn waitEvents(self: *Platform, timeout_ms: i32) u32 {
        if (self.closed) return 0;
        return switch (self.backend) {
            inline else => |*b| b.waitEvents(
                &self.reg,
                &self.events,
                &self.input_state,
                timeout_ms,
            ),
        };
    }

    /// Acorda uma thread bloqueada em `waitEvents` (de outra thread).
    /// Seguro para chamar a qualquer momento; sem efeito se ninguem
    /// espera.
    pub fn wakeup(self: *Platform) void {
        if (self.closed) return;
        switch (self.backend) {
            inline else => |*b| b.wakeup(),
        }
    }

    pub fn nextEvent(self: *Platform) ?Event {
        if (self.closed) return null;
        return self.events.next();
    }

    /// Injeta um evento sintetico (testes/ferramentas). Atualiza o input
    /// como um evento nativo. No-op apos deinit.
    pub fn injectEvent(self: *Platform, event: Event) void {
        if (self.closed) return;
        events.dispatch(&self.events, &self.input_state, event);
    }

    pub fn isWindowAlive(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return false;
        return self.reg.get(id) != null;
    }

    /// Invalido ou plataforma encerrada -> true (falha segura).
    pub fn windowShouldClose(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return true;
        const slot = self.reg.get(id) orelse return true;
        return slot.should_close;
    }

    pub fn requestWindowClose(self: *Platform, id: types.WindowId) void {
        if (self.closed) return;
        const slot = self.reg.get(id) orelse return;
        slot.should_close = true;
    }

    pub fn windowSize(self: *Platform, id: types.WindowId) types.WindowSize {
        if (self.closed) return .{ .width = 0, .height = 0 };
        const slot = self.reg.get(id) orelse return .{ .width = 0, .height = 0 };
        return .{ .width = slot.width, .height = slot.height };
    }

    /// Posicao atual da origem da area de cliente, em coordenadas de tela.
    /// Invalido/plataforma fechada -> {0,0} (falha segura).
    pub fn windowPosition(self: *Platform, id: types.WindowId) types.WindowPosition {
        if (self.closed) return .{ .x = 0, .y = 0 };
        const index = self.reg.indexOf(id) orelse return .{ .x = 0, .y = 0 };
        return switch (self.backend) {
            inline else => |*b| b.position(&self.reg, index),
        };
    }

    pub fn isWindowVisible(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return false;
        const slot = self.reg.get(id) orelse return false;
        return slot.visible;
    }

    pub fn isWindowFocused(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return false;
        const slot = self.reg.get(id) orelse return false;
        return slot.focused;
    }

    fn validateSizeLimits(limits: types.WindowSizeLimits) !void {
        if (limits.min_width > 16384 or limits.min_height > 16384 or
            limits.max_width > 16384 or limits.max_height > 16384)
        {
            return error.InvalidConfig;
        }
        if (limits.max_width != 0 and limits.min_width > limits.max_width) {
            return error.InvalidConfig;
        }
        if (limits.max_height != 0 and limits.min_height > limits.max_height) {
            return error.InvalidConfig;
        }
    }

    pub fn setWindowTitle(self: *Platform, id: types.WindowId, title: []const u8) !void {
        if (self.closed) return error.PlatformClosed;
        if (title.len > 1024) return error.InvalidConfig;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setTitle(&self.reg, index, title),
        }
    }

    /// Define limites minimo/maximo da area de cliente. `max_* == 0`
    /// significa sem maximo explicito naquele eixo. X11 aplica
    /// `WM_NORMAL_HINTS`; Win32 responde a `WM_GETMINMAXINFO`; null
    /// mantem o estado logico.
    pub fn setWindowSizeLimits(
        self: *Platform,
        id: types.WindowId,
        limits: types.WindowSizeLimits,
    ) !void {
        if (self.closed) return error.PlatformClosed;
        try validateSizeLimits(limits);
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setSizeLimits(&self.reg, index, limits),
        }
        self.reg.slots.items[index].size_limits = limits;
    }

    /// Limites configurados para a janela; invalido/fechado -> zero.
    pub fn windowSizeLimits(self: *Platform, id: types.WindowId) types.WindowSizeLimits {
        if (self.closed) return .{};
        const slot = self.reg.get(id) orelse return .{};
        return slot.size_limits;
    }

    pub fn setWindowSize(self: *Platform, id: types.WindowId, width: u32, height: u32) !void {
        if (self.closed) return error.PlatformClosed;
        if (width == 0 or height == 0) return error.InvalidConfig;
        if (width > 16384 or height > 16384) return error.InvalidConfig;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        // Sem atualizacao otimista: o slot reflete o ultimo tamanho
        // CONFIRMADO (via evento nativo ou backend sincrono).
        switch (self.backend) {
            inline else => |*b| try b.setSize(&self.reg, index, width, height),
        }
    }

    /// Move a origem da area de cliente para (x, y) em coordenadas de tela.
    /// X11 confirma via ConfigureNotify (evento `move`); Win32/null
    /// confirmam de forma sincrona.
    pub fn setWindowPosition(self: *Platform, id: types.WindowId, x: i32, y: i32) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setPosition(
                &self.reg,
                &self.events,
                &self.input_state,
                index,
                x,
                y,
            ),
        }
    }

    /// Solicita/remove fullscreen. X11/EWMH confirma via evento nativo;
    /// Win32/null aplicam de forma sincrona.
    pub fn setWindowFullscreen(self: *Platform, id: types.WindowId, fullscreen: bool) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setFullscreen(
                &self.reg,
                &self.events,
                &self.input_state,
                index,
                fullscreen,
            ),
        }
    }

    /// Estado de fullscreen atual. Id invalido/plataforma fechada -> false.
    pub fn isWindowFullscreen(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return false;
        const index = self.reg.indexOf(id) orelse return false;
        return switch (self.backend) {
            inline else => |*b| b.isFullscreen(&self.reg, index),
        };
    }

    /// Solicita/remove maximizacao. X11/EWMH confirma via evento nativo;
    /// Win32/null aplicam de forma sincrona. Fullscreen e maximizado sao
    /// mutuamente exclusivos (`WindowStateFailed` se o outro estiver ativo).
    pub fn setWindowMaximized(self: *Platform, id: types.WindowId, maximized: bool) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setMaximized(
                &self.reg,
                &self.events,
                &self.input_state,
                index,
                maximized,
            ),
        }
    }

    /// Estado de maximizacao atual. Id invalido/plataforma fechada -> false.
    pub fn isWindowMaximized(self: *Platform, id: types.WindowId) bool {
        if (self.closed) return false;
        const index = self.reg.indexOf(id) orelse return false;
        return switch (self.backend) {
            inline else => |*b| b.isMaximized(&self.reg, index),
        };
    }

    pub fn setWindowVisible(self: *Platform, id: types.WindowId, visible: bool) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setVisible(&self.reg, index, visible),
        }
    }

    pub fn focusWindow(self: *Platform, id: types.WindowId) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.focusWindow(&self.reg, index),
        }
    }

    pub fn setWindowCursor(self: *Platform, id: types.WindowId, cursor: types.Cursor) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.setCursor(&self.reg, index, cursor),
        }
    }

    pub fn captureWindowPointer(self: *Platform, id: types.WindowId) !void {
        if (self.closed) return error.PlatformClosed;
        const index = self.reg.indexOf(id) orelse return error.InvalidWindow;
        switch (self.backend) {
            inline else => |*b| try b.capturePointer(&self.reg, index),
        }
    }

    /// Liberacao best-effort: idempotente, segura apos deinit e para ids
    /// invalidos (nao ha erro a recuperar no caminho de cleanup).
    pub fn releaseWindowPointer(self: *Platform, id: types.WindowId) void {
        if (self.closed) return;
        const index = self.reg.indexOf(id) orelse return;
        switch (self.backend) {
            inline else => |*b| b.releasePointer(&self.reg, index),
        }
    }

    pub fn inputState(self: *const Platform) *const input.InputState {
        return &self.input_state;
    }

    /// Total de eventos descartados por overflow desde o init
    /// (diagnostico; ver politica de descarte em events.zig). Consumir
    /// a fila normalmente nao altera o contador.
    pub fn droppedEvents(self: *const Platform) u64 {
        return self.events.dropped;
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

test "droppedEvents exposes overflow diagnostics" {
    var plat = try Platform.init(std.testing.allocator, .{
        .backend = .null_backend,
        .event_queue_capacity = 1,
    });
    defer plat.deinit();
    const id: types.WindowId = .{ .index = 0, .generation = 0 };

    plat.injectEvent(.{ .close = .{ .window = id } });
    try std.testing.expectEqual(@as(u64, 0), plat.droppedEvents());

    // Fila (capacidade 1) cheia de um critico: o segundo close e
    // descartado e contabilizado.
    plat.injectEvent(.{ .close = .{ .window = id } });
    try std.testing.expectEqual(@as(u64, 1), plat.droppedEvents());

    // Consumir a fila nao zera o diagnostico.
    try std.testing.expect(plat.nextEvent() != null);
    try std.testing.expectEqual(@as(u64, 1), plat.droppedEvents());
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
    plat.injectEvent(.{ .fullscreen = .{ .window = id1, .fullscreen = true } });
    plat.injectEvent(.{ .maximized = .{ .window = id1, .maximized = true } });

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
    try std.testing.expectError(error.InvalidWindow, plat.setWindowPosition(id, 10, 10));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowSizeLimits(id, .{}));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowFullscreen(id, true));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowMaximized(id, true));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowVisible(id, true));
    try std.testing.expectError(error.InvalidWindow, plat.focusWindow(id));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowCursor(id, .text));
    try std.testing.expectError(error.InvalidWindow, plat.captureWindowPointer(id));
    plat.releaseWindowPointer(id); // no-op
}

test "set cursor on null backend succeeds" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    defer w.deinit();

    // Delegacao Window -> Platform -> backend; null aceita como no-op.
    try w.setCursor(.text);
    try w.setCursor(.default);
    try plat.setWindowCursor(w.windowId(), .wait);
}

test "pointer capture on null backend succeeds" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var first = try plat.createWindow(.{});
    defer first.deinit();
    var second = try plat.createWindow(.{});
    defer second.deinit();

    try first.capturePointer();
    try first.capturePointer(); // idempotente
    try second.capturePointer(); // transfere a captura
    first.releasePointer(); // no-op: nao detem mais
    second.releasePointer();
    second.releasePointer(); // idempotente
}

test "null backend reports no displays" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    const displays = try plat.displays(std.testing.allocator);
    defer std.testing.allocator.free(displays);
    try std.testing.expectEqual(@as(usize, 0), displays.len);
}

test "display change injection is global and coalesced" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    plat.injectEvent(.{ .display_change = .{} });
    plat.injectEvent(.{ .display_change = .{} });

    const event = plat.nextEvent() orelse return error.TestExpectedDisplayChange;
    try std.testing.expect(event == .display_change);
    try std.testing.expect(event.window() == null);
    try std.testing.expect(plat.nextEvent() == null);
}

test "window position on null backend updates state and emits move" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    defer w.deinit();

    var pos = w.position();
    try std.testing.expectEqual(@as(i32, 0), pos.x);
    try std.testing.expectEqual(@as(i32, 0), pos.y);

    try w.setPosition(120, 80);
    pos = w.position();
    try std.testing.expectEqual(@as(i32, 120), pos.x);
    try std.testing.expectEqual(@as(i32, 80), pos.y);

    const event = plat.nextEvent() orelse return error.TestExpectedMoveEvent;
    try std.testing.expect(event == .move);
    try std.testing.expect(event.move.window.eql(w.windowId()));
    try std.testing.expectEqual(@as(i32, 120), event.move.x);
    try std.testing.expectEqual(@as(i32, 80), event.move.y);

    // Mesma posicao: sem evento duplicado.
    try w.setPosition(120, 80);
    try std.testing.expect(plat.nextEvent() == null);
}

test "clipboard on null backend round-trips text" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    // Sem conteudo: null.
    try std.testing.expect(try plat.clipboardText(std.testing.allocator) == null);

    try plat.setClipboardText("ola mundo");
    const text = (try plat.clipboardText(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ola mundo", text);

    // Unicode (UTF-8) preservado.
    try plat.setClipboardText("acentuacao: áéíóú ç / 中文");
    const utf8 = (try plat.clipboardText(std.testing.allocator)).?;
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("acentuacao: áéíóú ç / 中文", utf8);

    // Texto vazio e tratado como area vazia.
    try plat.setClipboardText("");
    try std.testing.expect(try plat.clipboardText(std.testing.allocator) == null);
}

test "clipboard on closed platform fails safely" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    plat.deinit();

    try std.testing.expectError(error.PlatformClosed, plat.setClipboardText("x"));
    try std.testing.expect(try plat.clipboardText(std.testing.allocator) == null);
}

test "display modes are empty on null backend and switching is unsupported" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    const modes = try plat.displayModes(std.testing.allocator, .{ .raw = 0 });
    defer std.testing.allocator.free(modes);
    try std.testing.expectEqual(@as(usize, 0), modes.len);

    try std.testing.expectError(
        error.DisplayModeUnsupported,
        plat.setDisplayMode(.{ .raw = 0 }, .{ .raw = 42 }),
    );
    try std.testing.expectError(
        error.InvalidDisplayMode,
        plat.setDisplayMode(.{ .raw = 0 }, types.DisplayModeId.invalid),
    );
}

test "fullscreen on null backend updates state and emits fullscreen events" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    defer w.deinit();
    const id = w.windowId();

    try std.testing.expect(!w.isFullscreen());
    try w.setFullscreen(true);
    try std.testing.expect(w.isFullscreen());

    const on = plat.nextEvent() orelse return error.TestExpectedFullscreenEvent;
    try std.testing.expect(on == .fullscreen);
    try std.testing.expect(on.fullscreen.window.eql(id));
    try std.testing.expect(on.window().?.eql(id));
    try std.testing.expect(on.fullscreen.fullscreen);

    // Idempotente: sem evento duplicado.
    try w.setFullscreen(true);
    try std.testing.expect(plat.nextEvent() == null);

    try w.setFullscreen(false);
    try std.testing.expect(!w.isFullscreen());
    const off = plat.nextEvent() orelse return error.TestExpectedFullscreenEvent;
    try std.testing.expect(off == .fullscreen);
    try std.testing.expect(off.fullscreen.window.eql(id));
    try std.testing.expect(!off.fullscreen.fullscreen);

    try w.setFullscreen(false);
    try std.testing.expect(plat.nextEvent() == null);
    try std.testing.expect(!plat.isWindowFullscreen(.{ .index = 99, .generation = 0 }));
}

test "maximize on null backend updates state and enforces exclusivity" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    defer w.deinit();
    const id = w.windowId();

    try std.testing.expect(!w.isMaximized());
    try w.setMaximized(true);
    try std.testing.expect(w.isMaximized());

    const on = plat.nextEvent() orelse return error.TestExpectedMaximizedEvent;
    try std.testing.expect(on == .maximized);
    try std.testing.expect(on.maximized.window.eql(id));
    try std.testing.expect(on.window().?.eql(id));
    try std.testing.expect(on.maximized.maximized);

    // Idempotente: sem evento duplicado.
    try w.setMaximized(true);
    try std.testing.expect(plat.nextEvent() == null);

    // Fullscreen e maximizado sao mutuamente exclusivos.
    try std.testing.expectError(error.WindowStateFailed, w.setFullscreen(true));
    try std.testing.expect(!w.isFullscreen());
    try std.testing.expect(w.isMaximized());

    try w.setMaximized(false);
    try std.testing.expect(!w.isMaximized());
    const off = plat.nextEvent() orelse return error.TestExpectedMaximizedEvent;
    try std.testing.expect(off == .maximized);
    try std.testing.expect(!off.maximized.maximized);

    try w.setFullscreen(true);
    try std.testing.expect(w.isFullscreen());
    try std.testing.expectError(error.WindowStateFailed, w.setMaximized(true));
    try std.testing.expect(w.isFullscreen());
    try std.testing.expect(!w.isMaximized());

    // Descarta os eventos restantes (fullscreen).
    while (plat.nextEvent()) |_| {}
    try std.testing.expect(!plat.isWindowMaximized(.{ .index = 99, .generation = 0 }));
}

test "size limits on null backend validate and persist" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w = try plat.createWindow(.{});
    defer w.deinit();

    const initial = w.sizeLimits();
    try std.testing.expectEqual(@as(u32, 0), initial.min_width);

    try w.setSizeLimits(.{
        .min_width = 200,
        .min_height = 150,
        .max_width = 800,
        .max_height = 600,
    });
    const limits = w.sizeLimits();
    try std.testing.expectEqual(@as(u32, 200), limits.min_width);
    try std.testing.expectEqual(@as(u32, 150), limits.min_height);
    try std.testing.expectEqual(@as(u32, 800), limits.max_width);
    try std.testing.expectEqual(@as(u32, 600), limits.max_height);

    // Um maximo zero significa "sem limite" naquele eixo.
    try w.setSizeLimits(.{ .min_width = 100, .max_width = 0, .max_height = 400 });
    const partial = w.sizeLimits();
    try std.testing.expectEqual(@as(u32, 100), partial.min_width);
    try std.testing.expectEqual(@as(u32, 0), partial.max_width);
    try std.testing.expectEqual(@as(u32, 400), partial.max_height);

    // Validacao antes do backend: estado anterior e preservado.
    try std.testing.expectError(error.InvalidConfig, w.setSizeLimits(.{
        .min_width = 500,
        .max_width = 400,
    }));
    try std.testing.expectError(error.InvalidConfig, w.setSizeLimits(.{ .min_height = 500, .max_height = 400 }));
    try std.testing.expectError(error.InvalidConfig, w.setSizeLimits(.{ .max_width = 20000 }));
    try std.testing.expectEqual(@as(u32, 100), w.sizeLimits().min_width);

    // Ids invalidos falham de forma segura.
    const dead: types.WindowId = .{ .index = 99, .generation = 0 };
    try std.testing.expectError(error.InvalidWindow, plat.setWindowSizeLimits(dead, .{}));
    const dead_limits = plat.windowSizeLimits(dead);
    try std.testing.expectEqual(@as(u32, 0), dead_limits.min_width);
}

test "double deinit is safe" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    _ = try plat.createWindow(.{});
    plat.deinit();
    plat.deinit(); // no-op, sem double-free
}

test "operations after deinit fail safe" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    var w = try plat.createWindow(.{});
    const id = w.windowId();
    plat.deinit();

    try std.testing.expectError(error.PlatformClosed, plat.createWindow(.{}));
    try std.testing.expectError(error.PlatformClosed, plat.destroyWindow(id));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowTitle(id, "x"));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowPosition(id, 10, 10));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowSizeLimits(id, .{}));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowFullscreen(id, true));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowMaximized(id, true));
    try std.testing.expectError(error.PlatformClosed, plat.setWindowCursor(id, .text));
    try std.testing.expectError(error.PlatformClosed, plat.captureWindowPointer(id));
    plat.releaseWindowPointer(id); // no-op apos deinit
    plat.pollEvents(); // no-op
    plat.injectEvent(.{ .close = .{ .window = id } }); // no-op
    try std.testing.expect(plat.nextEvent() == null);
    try std.testing.expect(plat.windowShouldClose(id));
    try std.testing.expect(!plat.isWindowAlive(id));
    try std.testing.expect(!plat.isWindowFullscreen(id));
    try std.testing.expect(!plat.isWindowMaximized(id));
    const closed_limits = plat.windowSizeLimits(id);
    try std.testing.expectEqual(@as(u32, 0), closed_limits.min_width);
    const closed_pos = plat.windowPosition(id);
    try std.testing.expectEqual(@as(i32, 0), closed_pos.x);
    try std.testing.expectEqual(@as(i32, 0), closed_pos.y);
    const displays = try plat.displays(std.testing.allocator);
    defer std.testing.allocator.free(displays);
    try std.testing.expectEqual(@as(usize, 0), displays.len);
    // Window.deinit apos platform.deinit: erro ignorado, handle invalida.
    w.deinit();
    try std.testing.expect(!w.isValid());
}

test "reinit after deinit starts clean" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    _ = try plat.createWindow(.{});
    plat.deinit();

    plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    // Estado anterior nao vaza: slot 0 geracao 0 de novo, fila vazia.
    var w2 = try plat.createWindow(.{});
    defer w2.deinit();
    try std.testing.expect(plat.nextEvent() == null);
    try std.testing.expect(!plat.inputState().isKeyDown(.a));
}

test "multiple platform instances are independent" {
    // Politica multi-instancia: cada Platform detem recursos proprios
    // (no Win32, classes de janela com nomes unicos; no X11, conexoes
    // proprias). Filas, inputs e ids nao se misturam.
    var p1 = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer p1.deinit();
    var p2 = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer p2.deinit();

    var a = try p1.createWindow(.{ .title = "a" });
    defer a.deinit();
    var b = try p2.createWindow(.{ .title = "b" });
    defer b.deinit();

    p1.injectEvent(.{ .key_down = .{
        .window = a.windowId(),
        .key = .space,
        .modifiers = .{},
        .repeat = false,
    } });
    try std.testing.expect(p1.inputState().isKeyDown(.space));
    try std.testing.expect(!p2.inputState().isKeyDown(.space));
    try std.testing.expect(p1.nextEvent() != null);
    try std.testing.expect(p2.nextEvent() == null);

    // Ids iguais em instancias distintas nao se confundem.
    try std.testing.expect(a.windowId().eql(b.windowId()));
    try std.testing.expect(p1.isWindowAlive(a.windowId()));
    try std.testing.expect(p2.isWindowAlive(b.windowId()));
}

test "failed create preserves previous windows" {
    // Cenario C: falha controlada (config invalida) nao consome slot
    // nem afeta as janelas ja criadas.
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{ .width = 100, .height = 100 });
    defer w1.deinit();
    var w2 = try plat.createWindow(.{ .width = 200, .height = 200 });
    defer w2.deinit();

    try std.testing.expectError(error.InvalidConfig, plat.createWindow(.{ .width = 0, .height = 10 }));
    try std.testing.expect(w1.isValid());
    try std.testing.expect(w2.isValid());
    try std.testing.expectEqual(@as(u32, 100), w1.size().width);
    try std.testing.expectEqual(@as(u32, 200), w2.size().width);

    // Nenhum slot consumido: proxima janela reutiliza a ordem natural.
    var w3 = try plat.createWindow(.{});
    defer w3.deinit();
    try std.testing.expectEqual(@as(u32, 2), w3.windowId().index);
}

test "three windows destroy middle keeps others" {
    // Cenario A: primeira e terceira seguem utilizaveis; o indice do
    // meio e reutilizado com geracao maior.
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{ .title = "um" });
    defer w1.deinit();
    var w2 = try plat.createWindow(.{ .title = "dois" });
    var w3 = try plat.createWindow(.{ .title = "tres" });
    defer w3.deinit();
    const dead = w2.windowId();

    plat.injectEvent(.{ .resize = .{
        .window = dead,
        .width = 10,
        .height = 10,
    } });
    plat.injectEvent(.{ .resize = .{
        .window = w3.windowId(),
        .width = 30,
        .height = 30,
    } });

    try plat.destroyWindow(dead);
    w2.id = types.WindowId.invalid;

    try std.testing.expect(w1.isValid());
    try std.testing.expect(w3.isValid());
    try std.testing.expect(!plat.isWindowAlive(dead));

    // Evento da janela morta foi podado; o de w3 permanece.
    const ev = plat.nextEvent().?;
    try std.testing.expect(ev == .resize);
    try std.testing.expect(ev.resize.window.eql(w3.windowId()));
    try std.testing.expect(plat.nextEvent() == null);

    // Reutilizacao do indice com geracao maior.
    var w4 = try plat.createWindow(.{});
    defer w4.deinit();
    try std.testing.expectEqual(dead.index, w4.windowId().index);
    try std.testing.expect(w4.windowId().generation > dead.generation);
}

test "destroy clears stale pointer window in input state" {
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{});
    var w2 = try plat.createWindow(.{});
    defer w2.deinit();
    const id1 = w1.windowId();

    plat.injectEvent(.{ .pointer_move = .{ .window = id1, .x = 5, .y = 6 } });
    try std.testing.expect(plat.inputState().pointer_window.?.eql(id1));

    try plat.destroyWindow(id1);
    w1.id = types.WindowId.invalid;

    // Estado de input nao referencia mais a janela destruida.
    try std.testing.expect(plat.inputState().pointer_window == null);
    // Janela viva continua intacta.
    try std.testing.expect(w2.isValid());
}

test "destroy does not disturb keys or buttons held elsewhere" {
    // Destroy nao pode descarregar teclas/botoes de outras janelas: o
    // estado de input e global e so a referencia de ponteiro e por janela.
    var plat = try Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();

    var w1 = try plat.createWindow(.{});
    var w2 = try plat.createWindow(.{});
    defer w2.deinit();

    plat.injectEvent(.{ .key_down = .{
        .window = w2.windowId(),
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });
    plat.injectEvent(.{ .pointer_button = .{
        .window = w2.windowId(),
        .button = .left,
        .pressed = true,
        .x = 0,
        .y = 0,
        .modifiers = .{},
    } });

    try plat.destroyWindow(w1.windowId());
    w1.id = types.WindowId.invalid;

    try std.testing.expect(plat.inputState().isKeyDown(.a));
    try std.testing.expect(plat.inputState().isButtonDown(.left));
}
