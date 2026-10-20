// Zigway Wayland: backend nativo do protocolo Wayland.
//
// Nao e XWayland: fala o wire protocol do Wayland direto com o
// compositor (via libwayland-client carregada em runtime).
//
// Escopo desta etapa (v0.5, em andamento):
//   - conexao com o compositor (socket `WAYLAND_DISPLAY`),
//   - registry: bind de wl_output, wl_seat, wl_compositor, wl_shm e
//     xdg_wm_base,
//   - outputs (monitores) via wl_output,
//   - janelas via xdg-shell (wl_surface + xdg_surface + xdg_toplevel),
//     com buffer shm para mapear a superficie,
//   - despacho assincrono dos eventos do compositor.
//
// Ainda NAO implementado (retornam `error.NotImplemented`):
// input (teclado/ponteiro exigem keymap XKB e wl_pointer), clipboard e
// modos de video.
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
const linux = std.os.linux;

comptime {
    // O backend Wayland usa syscalls do Linux (memfd/shm).
    if (@import("builtin").os.tag != .linux) {
        @compileError("backend Wayland: suportado apenas em Linux");
    }
}

/// Cor de fundo do buffer provisorio (a renderizacao real entra na
/// fase de graficos, v0.4).
const placeholder_color_argb: u32 = 0xFF1E1E1E;
const placeholder_color_xrgb: u32 = 0x001E1E1E;

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

/// Estado de uma janela (wl_surface + xdg_surface + xdg_toplevel).
const WindowEntry = struct {
    /// Slot no registro da plataforma (fonte de verdade da validade).
    slot: u32,
    surface: *api.wl_proxy,
    xdg_surface: *api.wl_proxy,
    toplevel: *api.wl_proxy,
    /// Versao negociada da wl_surface (define `damage` vs `damage_buffer`).
    surface_version: u32 = 1,
    /// Buffer shm anexado (null quando a janela esta desmapeada).
    buffer: ?*api.wl_proxy = null,
    /// Pool shm dono do buffer.
    pool: ?*api.wl_proxy = null,
    /// Tamanho do buffer atual (o que o compositor confirmou).
    width: u32 = 0,
    height: u32 = 0,
    /// Serial do `xdg_surface.configure` aguardando `ack_configure`.
    pending_serial: ?u32 = null,
    /// Tamanho pedido pelo compositor (0 = o cliente decide).
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    /// O `xdg_toplevel.configure` chegou (tamanho conhecido).
    size_known: bool = false,
    /// Fechamento pedido pelo compositor (evento `close`).
    pending_close: bool = false,
    /// O compositor confirmou uma nova configuracao (resize pendente).
    pending_resize: bool = false,
    /// A janela ja foi mapeada (o compositor confirmou o `configure`).
    mapped: bool = false,
    /// Um `configure` foi recebido e confirmado: a superficie pode
    /// receber buffer (o protocolo exige `ack_configure` antes).
    configured: bool = false,
    /// A janela deve estar visivel (buffer anexado). Invisible = commit
    /// sem buffer (superficie desmapeada).
    visible: bool = true,
    /// Estado de fullscreen/maximizacao reportado pelo compositor.
    pending_fullscreen: ?bool = null,
    pending_maximized: ?bool = null,
    fullscreen: bool = false,
    maximized: bool = false,
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

/// Callbacks do `wl_shm` (wayland-client-core.h).
const ShmListener = extern struct {
    format: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `wl_surface` (wayland-client-core.h).
const SurfaceListener = extern struct {
    enter: *const fn (?*anyopaque, ?*api.wl_proxy, ?*anyopaque) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*api.wl_proxy, ?*anyopaque) callconv(.c) void,
    preferred_buffer_scale: *const fn (?*anyopaque, ?*api.wl_proxy, i32) callconv(.c) void,
    preferred_buffer_transform: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `xdg_wm_base` (wayland-client-core.h).
const WmBaseListener = extern struct {
    ping: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `xdg_surface` (wayland-client-core.h).
const XdgSurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `xdg_toplevel` (wayland-client-core.h).
const XdgToplevelListener = extern struct {
    configure: *const fn (?*anyopaque, ?*api.wl_proxy, i32, i32, ?*api.wl_array) callconv(.c) void,
    close: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    configure_bounds: *const fn (?*anyopaque, ?*api.wl_proxy, i32, i32) callconv(.c) void,
    wm_capabilities: *const fn (?*anyopaque, ?*api.wl_proxy, ?*api.wl_array) callconv(.c) void,
};

/// Listeners do protocolo (endereco estavel: a libwayland guarda o
/// ponteiro).
const Listeners = struct {
    registry: RegistryListener,
    output: OutputListener,
    seat: SeatListener,
    shm: ShmListener,
    surface: SurfaceListener,
    wm_base: WmBaseListener,
    xdg_surface: XdgSurfaceListener,
    xdg_toplevel: XdgToplevelListener,
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
    /// Globals para janelas (xdg-shell).
    compositor: ?*api.wl_proxy = null,
    compositor_version: u32 = 0,
    shm: ?*api.wl_proxy = null,
    shm_version: u32 = 0,
    wm_base: ?*api.wl_proxy = null,
    wm_base_version: u32 = 0,
    /// Formatos de shm suportados pelo compositor.
    shm_formats: [16]u32 = undefined,
    shm_format_count: usize = 0,
    /// Janelas criadas por este backend.
    windows: std.ArrayList(WindowEntry) = .empty,
    /// Descritores de arquivo ja enviados ao compositor via SCM_RIGHTS:
    /// so podem ser fechados depois que a requisicao foi enviada (flush).
    pending_fds: std.ArrayList(i32) = .empty,
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
        .shm = .{
            .format = onShmFormat,
        },
        .surface = .{
            .enter = onSurfaceEnter,
            .leave = onSurfaceLeave,
            .preferred_buffer_scale = onSurfacePreferredScale,
            .preferred_buffer_transform = onSurfacePreferredTransform,
        },
        .wm_base = .{
            .ping = onWmBasePing,
        },
        .xdg_surface = .{
            .configure = onXdgSurfaceConfigure,
        },
        .xdg_toplevel = .{
            .configure = onXdgToplevelConfigure,
            .close = onXdgToplevelClose,
            .configure_bounds = onXdgToplevelConfigureBounds,
            .wm_capabilities = onXdgToplevelWmCapabilities,
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
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, api.interface_wl_output)) {
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
        } else if (std.mem.eql(u8, iface, api.interface_wl_seat)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.seat_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.seat_interface) orelse return;
            lib.proxy_add_listener(
                proxy,
                @ptrCast(&self.listeners.seat),
                @ptrCast(self),
            );
            self.seat = proxy;
        } else if (std.mem.eql(u8, iface, api.interface_wl_compositor)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.compositor_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.compositor_interface) orelse return;
            self.compositor = proxy;
            self.compositor_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_wl_shm)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.shm_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.shm_interface) orelse return;
            lib.proxy_add_listener(
                proxy,
                @ptrCast(&self.listeners.shm),
                @ptrCast(self),
            );
            self.shm = proxy;
            self.shm_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_xdg_wm_base)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.xdg_wm_base_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.xdg_wm_base_interface) orelse return;
            self.wm_base = proxy;
            self.wm_base_version = bind_version;
        }
    }

    fn outputByProxy(self: *State, proxy: *api.wl_proxy) ?*OutputState {
        for (self.outputs.items) |*out| {
            if (out.proxy == proxy) return out;
        }
        return null;
    }

    fn windowIndexBySlot(self: *State, slot: u32) ?usize {
        for (self.windows.items, 0..) |entry, i| {
            if (entry.slot == slot) return i;
        }
        return null;
    }

    fn windowIndexBySurface(self: *State, proxy: *api.wl_proxy) ?usize {
        for (self.windows.items, 0..) |entry, i| {
            if (entry.surface == proxy) return i;
        }
        return null;
    }

    fn windowIndexByXdgSurface(self: *State, proxy: *api.wl_proxy) ?usize {
        for (self.windows.items, 0..) |entry, i| {
            if (entry.xdg_surface == proxy) return i;
        }
        return null;
    }

    fn windowIndexByToplevel(self: *State, proxy: *api.wl_proxy) ?usize {
        for (self.windows.items, 0..) |entry, i| {
            if (entry.toplevel == proxy) return i;
        }
        return null;
    }

    /// Formato de shm escolhido (XRGB quando o compositor suporta).
    fn shmFormat(self: *const State) u32 {
        var i: usize = 0;
        while (i < self.shm_format_count) : (i += 1) {
            if (self.shm_formats[i] == api.wl_shm_format_xrgb8888) return api.wl_shm_format_xrgb8888;
        }
        return api.wl_shm_format_argb8888;
    }

    /// Fecha os descritores ja enviados ao compositor. So pode ser
    /// chamado depois de um flush bem-sucedido.
    fn closePendingFds(self: *State) void {
        for (self.pending_fds.items) |fd| {
            _ = linux.close(fd);
        }
        self.pending_fds.clearRetainingCapacity();
    }

    /// Anexa (ou reanexa) o buffer da janela e confirma o `configure`.
    ///
    /// O protocolo xdg-shell exige duas coisas: o `ack_configure` antes
    /// de qualquer commit com buffer ("unconfigured_buffer") e o buffer
    /// com o tamanho aceito pelo compositor ("invalid_size"). O
    /// compositor pode enviar o `xdg_toplevel.configure` antes ou depois
    /// do `xdg_surface.configure`, entao o ack e o commit ficam
    /// separados: o ack sai assim que o serial chega e o buffer so e
    /// anexado quando o tamanho tambem e conhecido.
    fn applyConfigure(self: *State, index: usize) void {
        const entry = &self.windows.items[index];

        // 1) Confirma o configure (o ack e obrigatorio para cada
        //    `xdg_surface.configure`).
        if (entry.pending_serial) |serial| {
            entry.pending_serial = null;
            requestU32(&self.symbols, entry.xdg_surface, api.xdg_surface_ack_configure, serial);
            entry.configured = true;
        }

        // 2) Sem o ack nao pode haver buffer no commit; sem o tamanho
        //    confirmado o commit seria rejeitado ("invalid_size").
        if (!entry.configured or !entry.size_known) return;

        const width = if (entry.pending_width > 0) entry.pending_width else entry.width;
        const height = if (entry.pending_height > 0) entry.pending_height else entry.height;
        if (width == 0 or height == 0) return;

        if (!entry.visible) {
            // Janela oculta: sem buffer a superficie fica desmapeada.
            requestAttach(&self.symbols, entry.surface, null);
            requestNoArgs(&self.symbols, entry.surface, api.wl_surface_commit);
            return;
        }

        const resized = entry.buffer == null or entry.width != width or entry.height != height;
        self.attachBuffer(index, width, height) catch return;
        if (resized) {
            requestNoArgs(&self.symbols, entry.surface, api.wl_surface_commit);
        }
    }

    /// Cria (se necessario) e anexa o buffer do tamanho pedido.
    fn attachBuffer(self: *State, index: usize, width: u32, height: u32) !void {
        const entry = &self.windows.items[index];
        if (entry.buffer == null or entry.width != width or entry.height != height) {
            const created = try createShmBuffer(self, self.allocator, width, height);
            if (entry.buffer) |old| {
                requestNoArgs(&self.symbols, old, api.wl_buffer_destroy);
                self.symbols.proxy_destroy(old);
            }
            if (entry.pool) |old_pool| {
                requestNoArgs(&self.symbols, old_pool, api.wl_shm_pool_destroy);
                self.symbols.proxy_destroy(old_pool);
            }
            entry.buffer = created.buffer;
            entry.pool = created.pool;
            entry.width = width;
            entry.height = height;
        }
        const buffer = entry.buffer;
        requestAttach(
            &self.symbols,
            entry.surface,
            if (buffer) |b| @as(?*anyopaque, @ptrCast(b)) else null,
        );
        if (entry.surface_version >= 4) {
            requestDamageBuffer(&self.symbols, entry.surface, @intCast(width), @intCast(height));
        } else {
            requestDamage(&self.symbols, entry.surface, @intCast(width), @intCast(height));
        }
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

// --- Requests do protocolo (atalhos para `wl_proxy_marshal_flags`) ---

fn requestNoArgs(lib: *api.Symbols, proxy: *api.wl_proxy, opcode: u32) void {
    _ = lib.proxy_marshal_flags(proxy, opcode, null, 0, 0);
}

fn requestU32(lib: *api.Symbols, proxy: *api.wl_proxy, opcode: u32, value: u32) void {
    _ = lib.proxy_marshal_flags(proxy, opcode, null, 0, 0, value);
}

fn requestI32(lib: *api.Symbols, proxy: *api.wl_proxy, opcode: u32, value: i32) void {
    _ = lib.proxy_marshal_flags(proxy, opcode, null, 0, 0, value);
}

fn requestString(lib: *api.Symbols, proxy: *api.wl_proxy, opcode: u32, value: [*:0]const u8) void {
    _ = lib.proxy_marshal_flags(proxy, opcode, null, 0, 0, value);
}

fn requestObject(lib: *api.Symbols, proxy: *api.wl_proxy, opcode: u32, value: ?*anyopaque) void {
    _ = lib.proxy_marshal_flags(proxy, opcode, null, 0, 0, value);
}

/// `wl_surface.attach`: buffer (anulavel), deslocamento x e y.
fn requestAttach(lib: *api.Symbols, proxy: *api.wl_proxy, buffer: ?*anyopaque) void {
    _ = lib.proxy_marshal_flags(proxy, api.wl_surface_attach, null, 0, 0, buffer, @as(i32, 0), @as(i32, 0));
}

/// `wl_surface.damage` (superficies ate a v3).
fn requestDamage(lib: *api.Symbols, proxy: *api.wl_proxy, width: i32, height: i32) void {
    _ = lib.proxy_marshal_flags(proxy, api.wl_surface_damage, null, 0, 0, @as(i32, 0), @as(i32, 0), width, height);
}

/// `wl_surface.damage_buffer` (v4+): dano em coordenadas do buffer.
fn requestDamageBuffer(lib: *api.Symbols, proxy: *api.wl_proxy, width: i32, height: i32) void {
    _ = lib.proxy_marshal_flags(proxy, api.wl_surface_damage_buffer, null, 0, 0, @as(i32, 0), @as(i32, 0), width, height);
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
        // eventos de propriedade dos outputs (geometry/mode/scale), do
        // seat (capabilities) e do shm (format).
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
        // Janelas antes dos globals: o xdg_wm_base nao pode ser
        // destruido com superficies vivas.
        while (state.windows.items.len > 0) {
            self.destroyWindowEntry(0);
        }
        state.windows.deinit(self.allocator);
        state.closePendingFds();
        state.pending_fds.deinit(self.allocator);
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

    /// Janela via xdg-shell: `wl_surface` + `xdg_surface` +
    /// `xdg_toplevel`. O compositor decide o tamanho final (confirmado
    /// pelo `configure`); o cliente anexa um buffer shm provisorio para
    /// mapear a superficie (a renderizacao real entra na fase de
    /// graficos).
    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        const st = self.state;
        const lib = &self.lib.symbols;
        const compositor = st.compositor orelse return error.NotImplemented;
        const wm_base = st.wm_base orelse return error.NotImplemented;
        if (st.shm == null) return error.NotImplemented;

        const surface_version = @min(
            st.compositor_version,
            @as(u32, @intCast(protocol.surface_interface.version)),
        );
        const xdg_version = @min(
            st.wm_base_version,
            @as(u32, @intCast(protocol.xdg_wm_base_interface.version)),
        );

        const surface = lib.proxy_marshal_flags(
            compositor,
            api.wl_compositor_create_surface,
            &protocol.surface_interface,
            surface_version,
            0,
            @as(?*anyopaque, null),
        ) orelse return error.WindowCreationFailed;
        errdefer lib.proxy_destroy(surface);

        const xdg_surface = lib.proxy_marshal_flags(
            wm_base,
            api.xdg_wm_base_get_xdg_surface,
            &protocol.xdg_surface_interface,
            xdg_version,
            0,
            @as(?*anyopaque, null),
            @as(?*anyopaque, @ptrCast(surface)),
        ) orelse return error.WindowCreationFailed;
        errdefer lib.proxy_destroy(xdg_surface);

        const toplevel = lib.proxy_marshal_flags(
            xdg_surface,
            api.xdg_surface_get_toplevel,
            &protocol.xdg_toplevel_interface,
            xdg_version,
            0,
            @as(?*anyopaque, null),
        ) orelse return error.WindowCreationFailed;
        errdefer lib.proxy_destroy(toplevel);

        lib.proxy_add_listener(surface, @ptrCast(&st.listeners.surface), @ptrCast(st));
        lib.proxy_add_listener(xdg_surface, @ptrCast(&st.listeners.xdg_surface), @ptrCast(st));
        lib.proxy_add_listener(toplevel, @ptrCast(&st.listeners.xdg_toplevel), @ptrCast(st));

        var title_buf: [1025:0]u8 = undefined;
        const title_len = @min(cfg.title.len, title_buf.len - 1);
        @memcpy(title_buf[0..title_len], cfg.title[0..title_len]);
        title_buf[title_len] = 0;
        requestString(lib, toplevel, api.xdg_toplevel_set_title, &title_buf);
        requestString(lib, toplevel, api.xdg_toplevel_set_app_id, "zigway");

        try st.windows.append(self.allocator, .{
            .slot = slot,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .surface_version = surface_version,
            .width = cfg.width,
            .height = cfg.height,
            .pending_width = cfg.width,
            .pending_height = cfg.height,
            .visible = cfg.visible,
        });
        errdefer _ = st.windows.pop();

        // Commit inicial: o compositor responde com `xdg_surface.configure`
        // (e `xdg_toplevel.configure`), que dispara a criacao do buffer.
        requestNoArgs(lib, surface, api.wl_surface_commit);
        _ = reg;
    }

    fn destroyWindowEntry(self: *Backend, index: usize) void {
        const st = self.state;
        const entry = &st.windows.items[index];
        const lib = &st.symbols;
        if (entry.buffer) |buffer| {
            requestNoArgs(lib, buffer, api.wl_buffer_destroy);
            lib.proxy_destroy(buffer);
            entry.buffer = null;
        }
        if (entry.pool) |pool| {
            requestNoArgs(lib, pool, api.wl_shm_pool_destroy);
            lib.proxy_destroy(pool);
            entry.pool = null;
        }
        // A ordem importa: o papel (toplevel) antes da xdg_surface, e a
        // wl_surface por ultimo.
        requestNoArgs(lib, entry.toplevel, api.xdg_toplevel_destroy);
        lib.proxy_destroy(entry.toplevel);
        requestNoArgs(lib, entry.xdg_surface, api.xdg_surface_destroy);
        lib.proxy_destroy(entry.xdg_surface);
        requestNoArgs(lib, entry.surface, api.wl_surface_destroy);
        lib.proxy_destroy(entry.surface);
        _ = st.windows.swapRemove(index);
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        const index = self.state.windowIndexBySlot(slot) orelse return;
        self.destroyWindowEntry(index);
    }

    pub fn setTitle(self: *Backend, reg: *registry.Registry, slot: u32, title: []const u8) !void {
        _ = reg;
        const st = self.state;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        var title_buf: [1025:0]u8 = undefined;
        const len = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..len], title[0..len]);
        title_buf[len] = 0;
        requestString(&self.lib.symbols, st.windows.items[index].toplevel, api.xdg_toplevel_set_title, &title_buf);
    }

    /// O Wayland nao permite ao cliente fixar o tamanho da janela: o
    /// compositor decide (o `configure` confirma o tamanho final).
    pub fn setSize(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        width: u32,
        height: u32,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }

    /// Limites via `xdg_toplevel.set_min_size`/`set_max_size`.
    pub fn setSizeLimits(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        limits: types.WindowSizeLimits,
    ) !void {
        _ = reg;
        const st = self.state;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        const lib = &self.lib.symbols;
        const toplevel = st.windows.items[index].toplevel;
        if (limits.min_width > 0 or limits.min_height > 0) {
            _ = lib.proxy_marshal_flags(
                toplevel,
                api.xdg_toplevel_set_min_size,
                null,
                0,
                0,
                @as(i32, @intCast(limits.min_width)),
                @as(i32, @intCast(limits.min_height)),
            );
        }
        if (limits.max_width > 0 or limits.max_height > 0) {
            _ = lib.proxy_marshal_flags(
                toplevel,
                api.xdg_toplevel_set_max_size,
                null,
                0,
                0,
                @as(i32, @intCast(limits.max_width)),
                @as(i32, @intCast(limits.max_height)),
            );
        }
    }

    /// O Wayland nao expoe a posicao da janela ao cliente.
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

    /// Fullscreen via `xdg_toplevel.set_fullscreen` (o compositor escolhe
    /// o output). O estado confirmado chega pelo `configure`.
    pub fn setFullscreen(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        fullscreen: bool,
    ) !void {
        _ = reg;
        _ = queue;
        _ = state;
        const st = self.state;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        const toplevel = st.windows.items[index].toplevel;
        if (fullscreen) {
            requestObject(&self.lib.symbols, toplevel, api.xdg_toplevel_set_fullscreen, null);
        } else {
            requestNoArgs(&self.lib.symbols, toplevel, api.xdg_toplevel_unset_fullscreen);
        }
    }

    pub fn isFullscreen(self: *const Backend, reg: *registry.Registry, slot: u32) bool {
        _ = reg;
        const index = self.state.windowIndexBySlot(slot) orelse return false;
        return self.state.windows.items[index].fullscreen;
    }

    /// Maximizacao via `xdg_toplevel.set_maximized`.
    pub fn setMaximized(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        maximized: bool,
    ) !void {
        _ = reg;
        _ = queue;
        _ = state;
        const st = self.state;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        const toplevel = st.windows.items[index].toplevel;
        if (maximized) {
            requestNoArgs(&self.lib.symbols, toplevel, api.xdg_toplevel_set_maximized);
        } else {
            requestNoArgs(&self.lib.symbols, toplevel, api.xdg_toplevel_unset_maximized);
        }
    }

    pub fn isMaximized(self: *const Backend, reg: *registry.Registry, slot: u32) bool {
        _ = reg;
        const index = self.state.windowIndexBySlot(slot) orelse return false;
        return self.state.windows.items[index].maximized;
    }

    /// Mostrar/ocultar: no Wayland, ocultar equivale a anexar um buffer
    /// nulo (a superficie e desmapeada) e fazer commit.
    pub fn setVisible(self: *Backend, reg: *registry.Registry, slot: u32, visible: bool) !void {
        _ = reg;
        const st = self.state;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        const entry = &st.windows.items[index];
        entry.visible = visible;
        if (visible) {
            if (entry.width == 0 or entry.height == 0) return;
            // O protocolo exige `ack_configure` antes de anexar buffer:
            // antes do primeiro `configure` a janela fica sem buffer
            // (e o compositor a mapeia quando o `configure` chegar).
            if (!entry.configured) return;
            try st.attachBuffer(index, entry.width, entry.height);
            requestNoArgs(&self.lib.symbols, entry.surface, api.wl_surface_commit);
        } else {
            if (!entry.configured) return;
            requestAttach(&self.lib.symbols, entry.surface, null);
            requestNoArgs(&self.lib.symbols, entry.surface, api.wl_surface_commit);
        }
    }

    /// O foco no Wayland e controlado pelo compositor (a_surface nao
    /// existe): nao ha request para focar uma janela.
    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
        return error.NotImplemented;
    }

    /// O cursor do sistema exige `wl_pointer` e o tema do compositor
    /// (fase de input).
    pub fn setCursor(self: *Backend, reg: *registry.Registry, slot: u32, cursor: types.Cursor) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = cursor;
        return error.NotImplemented;
    }

    /// O Wayland nao expoe captura exclusiva de ponteiro no protocolo
    /// base (a captura e do compositor).
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
        if (!self.state.failed) {
            // 1) Despacha o que ja foi lido do socket.
            if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
                self.state.failed = true;
            } else {
                // 2) Le novos eventos apenas se houver dados (nao bloqueia).
                const fd = self.lib.symbols.display_get_fd(self.display);
                if (fd < 0) {
                    self.state.failed = true;
                } else {
                    var fds = [_]std.posix.pollfd{
                        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
                    };
                    const ready = std.posix.poll(&fds, 0) catch 0;
                    if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
                        while (self.lib.symbols.display_prepare_read(self.display) != 0) {
                            if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
                                self.state.failed = true;
                                break;
                            }
                        }
                        if (!self.state.failed) {
                            if (self.lib.symbols.display_read_events(self.display) < 0) {
                                self.state.failed = true;
                            } else if (self.lib.symbols.display_dispatch_pending(self.display) < 0) {
                                self.state.failed = true;
                            }
                        }
                    }
                }
            }
        }

        // Envia as requisicoes pendentes e libera os descritores ja
        // transmitidos ao compositor.
        if (self.lib.symbols.display_flush(self.display) >= 0) {
            self.state.closePendingFds();
        }

        self.emitPending(reg, queue, state);
    }

    /// Converte o estado acumulado pelos callbacks em eventos da
    /// plataforma (resize, close, fullscreen, maximized).
    fn emitPending(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        if (self.state.failed) return;
        var i: usize = 0;
        while (i < self.state.windows.items.len) : (i += 1) {
            const entry = &self.state.windows.items[i];
            if (entry.slot >= reg.slots.items.len) continue;
            const slot = &reg.slots.items[entry.slot];
            if (!slot.occupied) continue;
            const wid = reg.idOf(entry.slot);

            if (entry.pending_close) {
                entry.pending_close = false;
                slot.should_close = true;
                events.dispatch(queue, state, .{ .close = .{ .window = wid } });
            }
            if (entry.pending_fullscreen) |fullscreen| {
                entry.pending_fullscreen = null;
                if (entry.fullscreen != fullscreen) {
                    entry.fullscreen = fullscreen;
                    events.dispatch(queue, state, .{ .fullscreen = .{
                        .window = wid,
                        .fullscreen = fullscreen,
                    } });
                }
            }
            if (entry.pending_maximized) |maximized| {
                entry.pending_maximized = null;
                if (entry.maximized != maximized) {
                    entry.maximized = maximized;
                    events.dispatch(queue, state, .{ .maximized = .{
                        .window = wid,
                        .maximized = maximized,
                    } });
                }
            }
            // O tamanho so e publicado quando o compositor confirma
            // (via configure). O primeiro `configure` tambem confirma o
            // mapeamento da janela, mesmo sem mudanca de tamanho.
            if (entry.pending_resize) {
                entry.pending_resize = false;
                const first = !entry.mapped;
                entry.mapped = true;
                if (first or slot.width != entry.width or slot.height != entry.height) {
                    slot.width = entry.width;
                    slot.height = entry.height;
                    events.dispatch(queue, state, .{ .resize = .{
                        .window = wid,
                        .width = entry.width,
                        .height = entry.height,
                    } });
                }
            }
        }
    }
};

// --- Criacao de buffer (shm) ---

const ShmBuffer = struct {
    pool: *api.wl_proxy,
    buffer: *api.wl_proxy,
};

/// Cria um pool shm e um buffer do tamanho pedido. O descritor do
/// memfd e enviado ao compositor via SCM_RIGHTS: so pode ser fechado
/// depois do flush (ate entao fica em `pending_fds`).
fn createShmBuffer(
    state: *State,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) !ShmBuffer {
    const shm = state.shm orelse return error.NotImplemented;
    const stride = width * 4;
    const size = stride * height;

    const fd = try std.posix.memfd_create("zigway-shm", 0);
    // O descritor e propriedade do `pending_fds` depois do registro
    // (ele so pode ser fechado depois que a requisicao foi enviada).
    var fd_owned = true;
    errdefer if (fd_owned) {
        _ = linux.close(fd);
    };

    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) {
        return error.WindowCreationFailed;
    }

    // Conteudo provisorio: a janela precisa de um buffer para ser
    // mapeada (a renderizacao real entra na fase de graficos).
    {
        const pixels = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        defer std.posix.munmap(pixels);
        fillPlaceholder(pixels, stride, width, height, state.shmFormat());
    }

    // O compositor recebe uma copia do descritor no flush; o nosso
    // descritor e fechado depois que a requisicao foi enviada.
    try state.pending_fds.append(allocator, fd);
    fd_owned = false;

    const pool = state.symbols.proxy_marshal_flags(
        shm,
        api.wl_shm_create_pool,
        &protocol.shm_pool_interface,
        state.shm_version,
        0,
        @as(?*anyopaque, null),
        @as(i32, @intCast(fd)),
        @as(i32, @intCast(size)),
    ) orelse return error.WindowCreationFailed;

    const buffer = state.symbols.proxy_marshal_flags(
        pool,
        api.wl_shm_pool_create_buffer,
        &protocol.buffer_interface,
        protocol.buffer_interface.version,
        0,
        @as(?*anyopaque, null),
        @as(i32, 0),
        @as(i32, @intCast(width)),
        @as(i32, @intCast(height)),
        @as(i32, @intCast(stride)),
        state.shmFormat(),
    ) orelse {
        requestNoArgs(&state.symbols, pool, api.wl_shm_pool_destroy);
        state.symbols.proxy_destroy(pool);
        return error.WindowCreationFailed;
    };

    return .{ .pool = pool, .buffer = buffer };
}

/// Preenche o buffer com uma cor solida (placeholder).
fn fillPlaceholder(
    pixels: []u8,
    stride: usize,
    width: u32,
    height: u32,
    format: u32,
) void {
    const color: u32 = if (format == api.wl_shm_format_argb8888)
        placeholder_color_argb
    else
        placeholder_color_xrgb;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = pixels[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x + 4 <= row.len) : (x += 4) {
            std.mem.writeInt(u32, row[x..][0..4], color, .little);
        }
    }
}

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

fn onShmFormat(data: ?*anyopaque, shm: ?*api.wl_proxy, format: u32) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = shm;
    if (state.shm_format_count >= state.shm_formats.len) return;
    state.shm_formats[state.shm_format_count] = format;
    state.shm_format_count += 1;
}

fn onSurfaceEnter(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    surface: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = surface;
    // Entrada do ponteiro: o input do Wayland vem na fase seguinte.
}

fn onSurfaceLeave(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    surface: ?*anyopaque,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = surface;
}

fn onSurfacePreferredScale(data: ?*anyopaque, proxy: ?*api.wl_proxy, scale: i32) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = scale;
    // Escala preferida: usada quando o cliente anexa o buffer (fase de
    // graficos).
}

fn onSurfacePreferredTransform(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    transform: u32,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = transform;
}

fn onWmBasePing(data: ?*anyopaque, wm_base: ?*api.wl_proxy, serial: u32) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const base = wm_base orelse return;
    // O compositor verifica a resposta ao ping: sem `pong`, a conexao
    // e considerada travada.
    requestU32(&state.symbols, base, api.xdg_wm_base_pong, serial);
}

fn onXdgSurfaceConfigure(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    serial: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const index = state.windowIndexByXdgSurface(proxy orelse return) orelse return;
    state.windows.items[index].pending_serial = serial;
    state.windows.items[index].pending_resize = true;
    state.applyConfigure(index);
}

fn onXdgToplevelConfigure(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    width: i32,
    height: i32,
    states: ?*api.wl_array,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const index = state.windowIndexByToplevel(proxy orelse return) orelse return;
    const entry = &state.windows.items[index];

    if (width > 0 and height > 0) {
        entry.pending_width = @intCast(width);
        entry.pending_height = @intCast(height);
    }
    entry.size_known = true;

    var maximized = false;
    var fullscreen = false;
    if (states) |array| {
        // O array e valido apenas durante o callback.
        if (array.size > 0 and array.data != null) {
            const bytes: usize = @intCast(array.size);
            const count = bytes / @sizeOf(u32);
            const atoms = @as([*]const u32, @ptrCast(@alignCast(array.data.?)))[0..count];
            for (atoms) |atom| {
                if (atom == api.xdg_toplevel_state_maximized) maximized = true;
                if (atom == api.xdg_toplevel_state_fullscreen) fullscreen = true;
            }
        }
    }
    entry.pending_maximized = maximized;
    entry.pending_fullscreen = fullscreen;

    state.applyConfigure(index);
}

fn onXdgToplevelClose(data: ?*anyopaque, proxy: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const index = state.windowIndexByToplevel(proxy orelse return) orelse return;
    state.windows.items[index].pending_close = true;
}

fn onXdgToplevelConfigureBounds(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = width;
    _ = height;
    // Limites de maximizacao do compositor (nao alteram o tamanho da
    // area de cliente).
}

fn onXdgToplevelWmCapabilities(
    data: ?*anyopaque,
    proxy: ?*api.wl_proxy,
    capabilities: ?*api.wl_array,
) callconv(.c) void {
    _ = data;
    _ = proxy;
    _ = capabilities;
}

/// Copia uma string C para um buffer fixo (sem terminador).
fn copyString(dest: []u8, src: [*:0]const u8) void {
    @memset(dest, 0);
    var i: usize = 0;
    while (i + 1 < dest.len and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
}
