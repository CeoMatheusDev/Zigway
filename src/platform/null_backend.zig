// Zigway Platform: backend headless ("null").
//
// Sem recursos nativos. Janelas existem apenas no registro; eventos chegam
// via injecao (`Platform.injectEvent`), o que permite testar lifecycle,
// fila e input sem display. Tambem e o fallback em SOs sem backend nativo.

const std = @import("std");
const registry = @import("registry.zig");
const events = @import("../events.zig");
const input = @import("../input.zig");
const window = @import("../window.zig");
const types = @import("../core/types.zig");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    /// Slot com captura de ponteiro (exclusiva), se houver.
    captured: ?u32 = null,
    /// Texto da area de transferencia (propriedade do backend).
    clipboard_text: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Backend) void {
        if (self.clipboard_text) |text| self.allocator.free(text);
        self.clipboard_text = null;
    }

    /// Sem display nativo: lista vazia (nao inventa monitores).
    pub fn displays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        _ = self;
        return allocator.alloc(types.DisplayInfo, 0);
    }

    /// Sem modo de video nativo: lista vazia.
    pub fn displayModes(
        self: *const Backend,
        allocator: std.mem.Allocator,
        id: types.DisplayId,
    ) ![]types.DisplayMode {
        _ = self;
        _ = id;
        return allocator.alloc(types.DisplayMode, 0);
    }

    /// Troca de modo de video nao e suportada pelo backend null.
    pub fn setDisplayMode(
        self: *const Backend,
        id: types.DisplayId,
        mode: types.DisplayModeId,
    ) !void {
        _ = self;
        _ = id;
        _ = mode;
        return error.DisplayModeUnsupported;
    }

    /// Sem seat nativo.
    pub fn seatCapabilities(self: *const Backend) ?types.SeatCapabilities {
        _ = self;
        return null;
    }

    /// Sem IME: nada a informar.
    pub fn setSurroundingText(
        self: *const Backend,
        reg: *const registry.Registry,
        id: types.WindowId,
        text: []const u8,
        cursor: u32,
    ) !void {
        _ = self;
        _ = reg;
        _ = id;
        _ = text;
        _ = cursor;
        return error.NotImplemented;
    }

    /// Sem escala (1:1).
    pub fn windowScale(self: *const Backend, reg: *const registry.Registry, id: types.WindowId) types.Scale {
        _ = self;
        _ = reg;
        _ = id;
        return .identity;
    }

    /// Sem buffer proprio: o tamanho logico e o fisico.
    pub fn windowBufferSize(self: *const Backend, reg: *const registry.Registry, id: types.WindowId) types.WindowSize {
        _ = self;
        const slot = reg.slotOf(id) orelse return .{ .width = 0, .height = 0 };
        return .{
            .width = reg.slots.items[slot].width,
            .height = reg.slots.items[slot].height,
        };
    }

    /// Escala 1:1.
    pub fn displayScale(self: *const Backend, id: types.DisplayId) types.Scale {
        _ = self;
        _ = id;
        return .identity;
    }

    /// Backend headless: nada e suportado natively.
    pub fn capabilities(self: *const Backend) types.Capabilities {
        _ = self;
        return .{};
    }

    /// Sem composicao (nao ha teclado nativo).
    pub fn compositionText(self: *const Backend, reg: *registry.Registry, id: types.WindowId) ?[]const u8 {
        _ = self;
        _ = reg;
        _ = id;
        return null;
    }

    /// Guarda o texto da area de transferencia (estado em memoria).
    pub fn setClipboardText(self: *Backend, text: []const u8) !void {
        if (self.clipboard_text) |old| self.allocator.free(old);
        self.clipboard_text = try self.allocator.dupe(u8, text);
    }

    /// Texto da area de transferencia (copia); null quando vazio.
    pub fn clipboardText(
        self: *const Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        _ = reg;
        _ = queue;
        _ = state;
        const text = self.clipboard_text orelse return null;
        if (text.len == 0) return null;
        return try allocator.dupe(u8, text);
    }

    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        _ = self;
        const entry = &reg.slots.items[slot];
        entry.width = cfg.width;
        entry.height = cfg.height;
        entry.visible = cfg.visible;
        entry.native_ptr = null;
        entry.native_id = 0;
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured == slot) self.captured = null;
    }

    /// Sem eventos nativos: nao ha o que esperar.
    pub fn waitEvents(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        timeout_ms: i32,
    ) u32 {
        _ = timeout_ms;
        self.poll(reg, queue, state);
        return 0;
    }

    /// Sem espera: nada a acordar.
    pub fn wakeup(self: *Backend) void {
        _ = self;
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        _ = self;
        _ = reg;
        _ = queue;
        _ = state;
    }

    pub fn setTitle(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        title: []const u8,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = title;
    }

    pub fn setSize(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        width: u32,
        height: u32,
    ) !void {
        _ = self;
        reg.slots.items[slot].width = width;
        reg.slots.items[slot].height = height;
    }

    pub fn setPosition(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        x: i32,
        y: i32,
    ) !void {
        _ = self;
        const entry = &reg.slots.items[slot];
        if (entry.x == x and entry.y == y) return;
        entry.x = x;
        entry.y = y;
        events.dispatch(queue, state, .{ .move = .{
            .window = reg.idOf(slot),
            .x = x,
            .y = y,
        } });
    }

    pub fn position(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) types.WindowPosition {
        _ = self;
        const entry = &reg.slots.items[slot];
        return .{ .x = entry.x, .y = entry.y };
    }

    pub fn setSizeLimits(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        limits: types.WindowSizeLimits,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = limits;
    }

    pub fn setFullscreen(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        fullscreen: bool,
    ) !void {
        _ = self;
        const entry = &reg.slots.items[slot];
        if (entry.fullscreen == fullscreen) return;
        if (fullscreen and entry.maximized) return error.WindowStateFailed;
        entry.fullscreen = fullscreen;
        events.dispatch(queue, state, .{ .fullscreen = .{
            .window = reg.idOf(slot),
            .fullscreen = fullscreen,
        } });
    }

    pub fn setMaximized(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        maximized: bool,
    ) !void {
        _ = self;
        const entry = &reg.slots.items[slot];
        if (entry.maximized == maximized) return;
        if (maximized and entry.fullscreen) return error.WindowStateFailed;
        entry.maximized = maximized;
        events.dispatch(queue, state, .{ .maximized = .{
            .window = reg.idOf(slot),
            .maximized = maximized,
        } });
    }

    pub fn isMaximized(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = self;
        return reg.slots.items[slot].maximized;
    }

    pub fn isFullscreen(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = self;
        return reg.slots.items[slot].fullscreen;
    }

    pub fn setVisible(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        visible: bool,
    ) !void {
        _ = self;
        reg.slots.items[slot].visible = visible;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
    }

    pub fn setCursor(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cursor: types.Cursor,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = cursor;
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        self.captured = slot;
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured == slot) self.captured = null;
    }
};
