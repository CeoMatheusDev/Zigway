// Zigway Wayland: backend nativo do protocolo Wayland.
//
// Nao e XWayland: fala o wire protocol do Wayland direto com o
// compositor (via libwayland-client carregada em runtime).
//
// Escopo desta etapa (v0.5, em andamento):
//   - conexao com o compositor (socket `WAYLAND_DISPLAY`),
//   - registry: bind de wl_output e wl_seat,
//   - outputs (monitores) via wl_output,
//   - despacho assincrono dos eventos do compositor.
//
// Ainda NAO implementado (retornam `error.NotImplemented`):
// janelas/superficies (wl_surface + xdg_shell), input (teclado/ponteiro
// exigem superficie e keymap), clipboard e modos de video.
//
// Os callbacks do protocolo recebem um ponteiro para `State`, que fica
// na heap: o `Backend` e movido quando a `Platform` e devolvida por
// valor, entao o endereco dele nao serve como `data` do listener.

const std = @import("std");
const api = @import("api.zig");
const protocol = @import("protocol.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");

/// Estado de um output (wl_output).
const OutputState = struct {
    proxy: *api.wl_proxy,
    /// Nome do output (evento `name`).
    name: [64]u8 = std.mem.zeroes([64]u8),
    make: [32]u8 = std.mem.zeroes([32]u8),
    model: [32]u8 = std.mem.zeroes([32]u8),
    /// Posicao logica na tela.
    x: i32 = 0,
    y: i32 = 0,
    /// Tamanho fisico (mm) e tamanho do modo (px).
    physical_width: i32 = 0,
    physical_height: i32 = 0,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    refresh: i32 = 0,
    /// Fator de escala (o tamanho logico e o modo dividido pela escala).
    scale: i32 = 1,
    has_mode: bool = false,
};

/// Callbacks do `wl_registry` (wayland-client-core.h).
const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?[*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `wl_output` (wayland-client-core.h).
const OutputListener = extern struct {
    geometry: *const fn (?*anyopaque, ?*api.wl_proxy, i32, i32, i32, i32, i32, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) void,
    mode: *const fn (?*anyopaque, ?*api.wl_proxy, u32, i32, i32, i32) callconv(.c) void,
    done: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    scale: *const fn (?*anyopaque, ?*api.wl_proxy, i32) callconv(.c) void,
    name: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    description: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
};

/// Callbacks do `wl_seat` (wayland-client-core.h).
const SeatListener = extern struct {
    capabilities: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
    name: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
};

/// Listeners do protocolo (endereco estavel: a libwayland guarda o
/// ponteiro).
const Listeners = struct {
    registry: RegistryListener,
    output: OutputListener,
    seat: SeatListener,
};

/// Estado mutavel do backend (heap, endereco estavel para os callbacks).
const State = struct {
    allocator: std.mem.Allocator,
    outputs: std.ArrayList(OutputState) = .empty,
    seat: ?*api.wl_proxy = null,
    /// Capacidades do seat (bits de `wl_seat_capability_*`).
    seat_capabilities: u32 = 0,
    /// A conexao foi encerrada por erro de protocolo.
    failed: bool = false,
    /// Simbolos da libwayland (copia estavel: os callbacks usam esta
    /// copia, o `DynLib` tem dono unico no `Backend`).
    symbols: api.Symbols = undefined,
    /// Listeners: a libwayland guarda o ponteiro, entao precisam de
    /// endereco estavel.
    listeners: Listeners = .{
        .registry = .{
            .global = onGlobal,
            .global_remove = onGlobalRemove,
        },
        .output = .{
            .geometry = onOutputGeometry,
            .mode = onOutputMode,
            .done = onOutputDone,
            .scale = onOutputScale,
            .name = onOutputName,
            .description = onOutputDescription,
        },
        .seat = .{
            .capabilities = onSeatCapabilities,
            .name = onSeatName,
        },
    },

    fn handleGlobal(
        self: *State,
        registry_proxy: *api.wl_proxy,
        name: u32,
        interface: [*:0]const u8,
        version: u32,
    ) void {
        const lib = &self.symbols;
        if (std.mem.eql(u8, std.mem.span(interface), api.interface_wl_output)) {
            // A versao negociada e a menor entre a do compositor e a da
            // nossa tabela (a tabela define os eventos que sabemos tratar).
            const bind_version = @min(version, @as(u32, @intCast(protocol.output_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.output_interface) orelse return;
            lib.proxy_add_listener(
                proxy,
                @ptrCast(&self.listeners.output),
                @ptrCast(self),
            );
            self.outputs.append(self.allocator, .{ .proxy = proxy }) catch {
                lib.proxy_destroy(proxy);
            };
        } else if (std.mem.eql(u8, std.mem.span(interface), api.interface_wl_seat)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.seat_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.seat_interface) orelse return;
            lib.proxy_add_listener(
                proxy,
                @ptrCast(&self.listeners.seat),
                @ptrCast(self),
            );
            self.seat = proxy;
        }
    }

    fn outputByProxy(self: *State, proxy: *api.wl_proxy) ?*OutputState {
        for (self.outputs.items) |*out| {
            if (out.proxy == proxy) return out;
        }
        return null;
    }
};

/// Faz `bind` de um global do registry e devolve o novo proxy.
///
/// `wl_registry.bind` usa o construtor `wl_interface`: o nome da
/// interface e a versao sao enviados como argumentos, e a interface do
/// objeto filho e informada para a libwayland cria-lo.
fn bindGlobal(
    lib: *api.Symbols,
    registry_proxy: *api.wl_proxy,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
    child: ?*const api.Interface,
) ?*api.wl_proxy {
    return lib.proxy_marshal_flags(
        registry_proxy,
        api.wl_registry_bind,
        child,
        version,
        0,
        name,
        interface,
        version,
        @as(?*anyopaque, null),
    );
}

pub const Backend = struct {
    allocator: std.mem.Allocator,
    lib: api.Lib,
    display: *api.wl_display,
    registry: *api.wl_proxy,
    /// Estado (heap): endereco estavel exigido pelos callbacks.
    state: *State,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        var lib = api.Lib.load() orelse return error.UnsupportedBackend;
        errdefer lib.deinit();
        const display = lib.symbols.display_connect(null) orelse return error.NoDisplay;
        errdefer lib.symbols.display_disconnect(display);

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .symbols = lib.symbols };

        // Registry: request `wl_display.get_registry`.
        const display_proxy: *api.wl_proxy = @ptrCast(display);
        const registry_proxy = lib.symbols.proxy_marshal_flags(
            display_proxy,
            api.wl_display_get_registry,
            &protocol.registry_interface,
            protocol.registry_interface.version,
            0,
            @as(?*anyopaque, null),
        ) orelse return error.ConnectionFailed;

        lib.symbols.proxy_add_listener(
            registry_proxy,
            @ptrCast(&state.listeners.registry),
            @ptrCast(state),
        );

        // Roundtrip: recebe os globals (wl_output, wl_seat, ...).
        if (lib.symbols.display_roundtrip(display) < 0) return error.ConnectionFailed;

        // Segundo roundtrip: os binds feitos acima recebem agora os
        // eventos de propriedade dos outputs (geometry/mode/scale) e do
        // seat (capabilities).
        if (lib.symbols.display_roundtrip(display) < 0) return error.ConnectionFailed;

        return .{
            .allocator = allocator,
            .lib = lib,
            .display = display,
            .registry = registry_proxy,
            .state = state,
        };
    }

    pub fn deinit(self: *Backend) void {
        const state = self.state;
        for (state.outputs.items) |out| self.lib.symbols.proxy_destroy(out.proxy);
        state.outputs.deinit(self.allocator);
        if (state.seat) |seat| self.lib.symbols.proxy_destroy(seat);
        self.lib.symbols.proxy_destroy(self.registry);
        self.lib.symbols.display_disconnect(self.display);
        self.allocator.destroy(state);
        self.lib.deinit();
    }

    /// Monitores (outputs) do compositor. O tamanho logico e o modo
    /// dividido pela escala do output.
    pub fn displays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        var list: std.ArrayList(types.DisplayInfo) = .empty;
        errdefer list.deinit(allocator);
        for (self.state.outputs.items) |out| {
            if (!out.has_mode) continue;
            const scale: i64 = if (out.scale > 0) out.scale else 1;
            const width = @divTrunc(@as(i64, out.mode_width), scale);
            const height = @divTrunc(@as(i64, out.mode_height), scale);
            if (width <= 0 or height <= 0) continue;
            try list.append(allocator, .{
                .id = .{ .raw = @intCast(list.items.len) },
                .x = out.x,
                .y = out.y,
                .width = @intCast(width),
                .height = @intCast(height),
                // O protocolo base nao informa o output primario: exige
                // xdg-output (pendente).
                .primary = false,
            });
        }
        return try list.toOwnedSlice(allocator);
    }

    /// Modos de video: o Wayland expoe os modos do compositor, mas a
    /// troca e do compositor (o cliente pede e o compositor aplica).
    pub fn displayModes(
        self: *const Backend,
        allocator: std.mem.Allocator,
        id: types.DisplayId,
    ) ![]types.DisplayMode {
        _ = self;
        _ = id;
        return allocator.alloc(types.DisplayMode, 0);
    }

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

    /// O X11/Win32 nao modelam um seat; no Wayland devolvemos as
    /// capacidades do compositor.
    pub fn seatCapabilities(self: *const Backend) ?types.SeatCapabilities {
        if (self.state.seat == null) return null;
        return .{
            .pointer = (self.state.seat_capabilities & api.wl_seat_capability_pointer) != 0,
            .keyboard = (self.state.seat_capabilities & api.wl_seat_capability_keyboard) != 0,
            .touch = (self.state.seat_capabilities & api.wl_seat_capability_touch) != 0,
        };
    }

    pub fn setClipboardText(self: *Backend, text: []const u8) !void {
        _ = self;
        _ = text;
        return error.NotImplemented;
    }

    pub fn clipboardText(
        self: *const Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        _ = self;
        _ = reg;
        _ = queue;
        _ = state;
        _ = allocator;
        return null;
    }

    /// Superficies (wl_surface + xdg_shell) ainda nao implementadas.
    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = cfg;
        return error.NotImplemented;
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = self;
        _ = reg;
        _ = slot;
    }

    pub fn setTitle(self: *Backend, reg: *registry.Registry, slot: u32, title: []const u8) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = title;
        return error.NotImplemented;
    }

    pub fn setSize(self: *Backend, reg: *registry.Registry, slot: u32, width: u32, height: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = width;
        _ = height;
        return error.NotImplemented;
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
        return error.NotImplemented;
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
        _ = reg;
        _ = queue;
        _ = state;
        _ = slot;
        _ = x;
        _ = y;
        return error.NotImplemented;
    }

    pub fn position(self: *const Backend, reg: *registry.Registry, slot: u32) types.WindowPosition {
        _ = self;
        _ = reg;
        _ = slot;
        return .{ .x = 0, .y = 0 };
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
        _ = reg;
        _ = queue;
        _ = state;
        _ = slot;
        _ = fullscreen;
        return error.NotImplemented;
    }

    pub fn isFullscreen(self: *const Backend, reg: *registry.Registry, slot: u32) bool {
        _ = self;
        _ = reg;
        _ = slot;
        return false;
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
        _ = reg;
        _ = queue;
        _ = state;
        _ = slot;
        _ = maximized;
        return error.NotImplemented;
    }

    pub fn isMaximized(self: *const Backend, reg: *registry.Registry, slot: u32) bool {
        _ = self;
        _ = reg;
        _ = slot;
        return false;
    }

    pub fn setVisible(self: *Backend, reg: *registry.Registry, slot: u32, visible: bool) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = visible;
        return error.NotImplemented;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
        return error.NotImplemented;
    }

    pub fn setCursor(self: *Backend, reg: *registry.Registry, slot: u32, cursor: types.Cursor) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = cursor;
        return error.NotImplemented;
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
        return error.NotImplemented;
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = self;
        _ = reg;
        _ = slot;
    }

    /// Despacha os eventos do compositor (sem bloquear).
    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        _ = reg;
        _ = queue;
        _ = state;
        if (self.state.failed) return;

        // 1) Despacha o que ja foi lido do socket.
        if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
            self.state.failed = true;
            return;
        }
        // 2) Le novos eventos apenas se houver dados (nao bloqueia).
        const fd = self.lib.symbols.display_get_fd(self.display);
        if (fd < 0) {
            self.state.failed = true;
            return;
        }
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, 0) catch 0;
        if (ready == 0) return;
        if (fds[0].revents & std.posix.POLL.IN == 0) return;

        while (self.lib.symbols.display_prepare_read(self.display) != 0) {
            if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
                self.state.failed = true;
                return;
            }
        }
        if (self.lib.symbols.display_read_events(self.display) < 0) {
            self.state.failed = true;
            return;
        }
        if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
            self.state.failed = true;
        }
    }
};

// --- Callbacks do protocolo ---

fn stateFrom(data: ?*anyopaque) ?*State {
    const ptr = data orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn onGlobal(
    data: ?*anyopaque,
    registry_proxy: ?*api.wl_proxy,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const reg = registry_proxy orelse return;
    const iface = interface orelse return;
    state.handleGlobal(reg, name, iface, version);
}

fn onGlobalRemove(
    data: ?*anyopaque,
    registry_proxy: ?*api.wl_proxy,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry_proxy;
    _ = name;
    // Remocao de global nao e tratada nesta etapa.
}

fn onOutputGeometry(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    x: i32,
    y: i32,
    physical_width: i32,
    physical_height: i32,
    subpixel: i32,
    make: ?[*:0]const u8,
    model: ?[*:0]const u8,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const out = state.outputByProxy(proxy orelse return) orelse return;
    out.x = x;
    out.y = y;
    out.physical_width = physical_width;
    out.physical_height = physical_height;
    _ = subpixel;
    if (make) |m| copyString(&out.make, m);
    if (model) |m| copyString(&out.model, m);
}

fn onOutputMode(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    flags: u32,
    width: i32,
    height: i32,
    refresh: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const out = state.outputByProxy(proxy orelse return) orelse return;
    if ((flags & api.wl_output_mode_current) != 0) {
        out.mode_width = width;
        out.mode_height = height;
        out.refresh = refresh;
        out.has_mode = true;
    }
}

fn onOutputDone(data: ?*anyopaque, proxy: ?*api.wl_proxy) callconv(.c) void {
    _ = data;
    _ = proxy;
    // Fim do lote de propriedades do output.
}

fn onOutputScale(data: ?*anyopaque, proxy: ?*api.wl_proxy, factor: i32) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const out = state.outputByProxy(proxy orelse return) orelse return;
    if (factor > 0) out.scale = factor;
}

fn onOutputName(data: ?*anyopaque, proxy: ?*api.wl_proxy, name: ?[*:0]const u8) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const out = state.outputByProxy(proxy orelse return) orelse return;
    if (name) |n| copyString(&out.name, n);
}

fn onOutputDescription(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    description: ?[*:0]const u8,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = description;
}

fn onSeatCapabilities(data: ?*anyopaque, seat: ?*api.wl_proxy, capabilities: u32) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = seat;
    state.seat_capabilities = capabilities;
}

fn onSeatName(data: ?*anyopaque, seat: ?*api.wl_proxy, name: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

/// Copia uma string C para um buffer fixo (sem terminador).
fn copyString(dest: []u8, src: [*:0]const u8) void {
    @memset(dest, 0);
    var i: usize = 0;
    while (i + 1 < dest.len and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
}
