// Zigway Wayland: ABI manual de libwayland-client (sem @cImport).
//
// A libwayland-client e carregada em RUNTIME (dlopen), como a
// libXrandr no backend X11: o build nao ganha dependencia de link e o
// backend simplesmente nao esta disponivel quando a biblioteca falta.
// A ABI e declarada manualmente aqui (sem headers C no build).
//
// O protocolo (wl_display, wl_registry, wl_output, wl_seat,
// wl_compositor) e o wire format do Wayland: os numeros de request e de
// evento vem da especificacao (wayland.xml) e sao estaveis (a versao
// negociada com o compositor define os eventos disponiveis).

const std = @import("std");
const protocol = @import("protocol.zig");

pub const Interface = protocol.Interface;

pub const wl_display = opaque {};
pub const wl_proxy = opaque {};
pub const wl_registry = opaque {};
pub const wl_compositor = opaque {};
pub const wl_output = opaque {};
pub const wl_seat = opaque {};
pub const wl_surface = opaque {};

/// `union wl_argument` (wayland-util.h): valor de um argumento de
/// request. No formato moderno o tipo vem da assinatura da mensagem.
pub const wl_argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*anyopaque,
    h: i32,
};

const ConnectFn = *const fn (?[*:0]const u8) callconv(.c) ?*wl_display;
const DisconnectFn = *const fn (*wl_display) callconv(.c) void;
const GetFdFn = *const fn (*wl_display) callconv(.c) c_int;
const DispatchPendingFn = *const fn (*wl_display) callconv(.c) c_int;
const PrepareReadFn = *const fn (*wl_display) callconv(.c) c_int;
const ReadEventsFn = *const fn (*wl_display) callconv(.c) c_int;
const RoundtripFn = *const fn (*wl_display) callconv(.c) c_int;
const FlushFn = *const fn (*wl_display) callconv(.c) c_int;
const MarshalArrayFn = *const fn (
    *wl_proxy,
    u32,
    ?[*]wl_argument,
    c_int,
) callconv(.c) ?*wl_proxy;
/// `wl_proxy_marshal_flags`: a interface e a versao do objeto filho sao
/// informadas (a libwayland cria o filho a partir delas).
const MarshalFlagsFn = *const fn (*wl_proxy, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*wl_proxy;
const ProxyDestroyFn = *const fn (*wl_proxy) callconv(.c) void;
const ProxyAddListenerFn = *const fn (
    *wl_proxy,
    ?*const anyopaque,
    ?*anyopaque,
) callconv(.c) void;

/// Ponteiros de funcao da libwayland-client (copia estavel, sem o
/// `DynLib`: o `DynLib` tem dono unico).
pub const Symbols = struct {
    display_connect: ConnectFn,
    display_disconnect: DisconnectFn,
    display_get_fd: GetFdFn,
    display_dispatch_pending: DispatchPendingFn,
    display_prepare_read: PrepareReadFn,
    display_read_events: ReadEventsFn,
    display_roundtrip: RoundtripFn,
    display_flush: FlushFn,
    proxy_marshal_array: MarshalArrayFn,
    proxy_marshal_flags: MarshalFlagsFn,
    proxy_destroy: ProxyDestroyFn,
    proxy_add_listener: ProxyAddListenerFn,
};

/// A libwayland-client carregada (dono do `DynLib`).
pub const Lib = struct {
    dyn: std.DynLib,
    symbols: Symbols,

    /// Carrega a libwayland-client. Retorna null se a biblioteca ou
    /// algum simbolo necessario nao existir.
    pub fn load() ?Lib {
        var dyn = std.DynLib.open("libwayland-client.so.0") catch blk: {
            break :blk std.DynLib.open("libwayland-client.so") catch return null;
        };
        const display_connect = dyn.lookup(ConnectFn, "wl_display_connect") orelse {
            dyn.close();
            return null;
        };
        const display_disconnect = dyn.lookup(DisconnectFn, "wl_display_disconnect") orelse {
            dyn.close();
            return null;
        };
        const display_get_fd = dyn.lookup(GetFdFn, "wl_display_get_fd") orelse {
            dyn.close();
            return null;
        };
        const display_dispatch_pending = dyn.lookup(DispatchPendingFn, "wl_display_dispatch_pending") orelse {
            dyn.close();
            return null;
        };
        const display_prepare_read = dyn.lookup(PrepareReadFn, "wl_display_prepare_read") orelse {
            dyn.close();
            return null;
        };
        const display_read_events = dyn.lookup(ReadEventsFn, "wl_display_read_events") orelse {
            dyn.close();
            return null;
        };
        const display_roundtrip = dyn.lookup(RoundtripFn, "wl_display_roundtrip") orelse {
            dyn.close();
            return null;
        };
        const display_flush = dyn.lookup(FlushFn, "wl_display_flush") orelse {
            dyn.close();
            return null;
        };
        const proxy_marshal_array = dyn.lookup(MarshalArrayFn, "wl_proxy_marshal_array") orelse {
            dyn.close();
            return null;
        };
        const proxy_marshal_flags = dyn.lookup(MarshalFlagsFn, "wl_proxy_marshal_flags") orelse {
            dyn.close();
            return null;
        };
        const proxy_destroy = dyn.lookup(ProxyDestroyFn, "wl_proxy_destroy") orelse {
            dyn.close();
            return null;
        };
        const proxy_add_listener = dyn.lookup(ProxyAddListenerFn, "wl_proxy_add_listener") orelse {
            dyn.close();
            return null;
        };
        return .{
            .dyn = dyn,
            .symbols = .{
                .display_connect = display_connect,
                .display_disconnect = display_disconnect,
                .display_get_fd = display_get_fd,
                .display_dispatch_pending = display_dispatch_pending,
                .display_prepare_read = display_prepare_read,
                .display_read_events = display_read_events,
                .display_roundtrip = display_roundtrip,
                .display_flush = display_flush,
                .proxy_marshal_array = proxy_marshal_array,
                .proxy_marshal_flags = proxy_marshal_flags,
                .proxy_destroy = proxy_destroy,
                .proxy_add_listener = proxy_add_listener,
            },
        };
    }

    pub fn deinit(self: *Lib) void {
        self.dyn.close();
    }
};

// --- Tipos de argumento (wayland-client.h) ---
pub const wl_argument_null: u32 = 0;
pub const wl_argument_int: u32 = 1;
pub const wl_argument_uint: u32 = 2;
pub const wl_argument_fixed: u32 = 3;
pub const wl_argument_string: u32 = 4;
pub const wl_argument_object: u32 = 5;
pub const wl_argument_new_id: u32 = 6;
pub const wl_argument_array: u32 = 7;

// --- Requests: wl_display ---
pub const wl_display_sync: u32 = 0;
pub const wl_display_get_registry: u32 = 1;

// --- Requests: wl_registry ---
pub const wl_registry_bind: u32 = 0;

// --- Events: wl_registry ---
pub const wl_registry_global: u32 = 0;
pub const wl_registry_global_remove: u32 = 1;

// --- Requests: wl_compositor ---
pub const wl_compositor_create_surface: u32 = 0;
pub const wl_compositor_create_region: u32 = 1;

// --- Requests: wl_output ---
pub const wl_output_release: u32 = 0;

// --- Events: wl_output ---
pub const wl_output_geometry: u32 = 0;
pub const wl_output_mode: u32 = 1;
pub const wl_output_done: u32 = 2;
pub const wl_output_scale: u32 = 3;
pub const wl_output_name: u32 = 4;
pub const wl_output_description: u32 = 5;

/// Flags de `wl_output.mode`.
pub const wl_output_mode_current: u32 = 0x1;
pub const wl_output_mode_preferred: u32 = 0x2;

// --- Requests: wl_seat ---
pub const wl_seat_get_pointer: u32 = 0;
pub const wl_seat_get_keyboard: u32 = 1;
pub const wl_seat_get_touch: u32 = 2;
pub const wl_seat_release: u32 = 3;

// --- Events: wl_seat ---
pub const wl_seat_capabilities: u32 = 0;
pub const wl_seat_name: u32 = 1;

/// Capacidades do seat.
pub const wl_seat_capability_pointer: u32 = 1;
pub const wl_seat_capability_keyboard: u32 = 2;
pub const wl_seat_capability_touch: u32 = 4;

/// Eixos do `wl_pointer.axis`.
pub const wl_pointer_axis_vertical_scroll: u32 = 0;
pub const wl_pointer_axis_horizontal_scroll: u32 = 1;

/// Formatos do `wl_keyboard.keymap`.
/// Texto XKB (o unico suportado pelo backend).
pub const wl_keyboard_keymap_format_xkb_v1: u32 = 1;

/// `struct wl_array` (wayland-util.h): vetor de bytes (usado pelos
/// estados do xdg_toplevel).
pub const wl_array = extern struct {
    size: c_int,
    alloc: c_int,
    data: ?[*]u8,
};

/// Nomes de interface do protocolo (usados em `wl_registry.bind`).
pub const interface_wl_compositor = "wl_compositor";
pub const interface_wl_output = "wl_output";
pub const interface_wl_seat = "wl_seat";
pub const interface_wl_surface = "wl_surface";
pub const interface_wl_shm = "wl_shm";
pub const interface_xdg_wm_base = "xdg_wm_base";

/// Interfaces do protocolo estavel (para binds futuros).
pub const interface_xdg_surface = "xdg_surface";
pub const interface_xdg_toplevel = "xdg_toplevel";

/// --- Requests: wl_surface ---
pub const wl_surface_destroy: u32 = 0;
pub const wl_surface_attach: u32 = 1;
pub const wl_surface_damage: u32 = 2;
pub const wl_surface_frame: u32 = 3;
pub const wl_surface_set_opaque_region: u32 = 4;
pub const wl_surface_set_input_region: u32 = 5;
pub const wl_surface_commit: u32 = 6;
pub const wl_surface_set_buffer_transform: u32 = 7;
pub const wl_surface_set_buffer_scale: u32 = 8;
pub const wl_surface_damage_buffer: u32 = 9;
pub const wl_surface_offset: u32 = 10;
pub const wl_surface_get_release: u32 = 11;

/// --- Requests: wl_shm / wl_shm_pool / wl_buffer ---
pub const wl_shm_create_pool: u32 = 0;
pub const wl_shm_release: u32 = 1;
pub const wl_shm_pool_create_buffer: u32 = 0;
pub const wl_shm_pool_destroy: u32 = 1;
pub const wl_shm_pool_resize: u32 = 2;
pub const wl_buffer_destroy: u32 = 0;

/// --- Requests: xdg_wm_base ---
pub const xdg_wm_base_destroy: u32 = 0;
pub const xdg_wm_base_create_positioner: u32 = 1;
pub const xdg_wm_base_get_xdg_surface: u32 = 2;
pub const xdg_wm_base_pong: u32 = 3;

/// --- Requests: xdg_surface ---
pub const xdg_surface_destroy: u32 = 0;
pub const xdg_surface_get_toplevel: u32 = 1;
pub const xdg_surface_get_popup: u32 = 2;
pub const xdg_surface_set_window_geometry: u32 = 3;
pub const xdg_surface_ack_configure: u32 = 4;

/// --- Requests: xdg_toplevel ---
pub const xdg_toplevel_destroy: u32 = 0;
pub const xdg_toplevel_set_parent: u32 = 1;
pub const xdg_toplevel_set_title: u32 = 2;
pub const xdg_toplevel_set_app_id: u32 = 3;
pub const xdg_toplevel_show_window_menu: u32 = 4;
pub const xdg_toplevel_move: u32 = 5;
pub const xdg_toplevel_resize: u32 = 6;
pub const xdg_toplevel_set_max_size: u32 = 7;
pub const xdg_toplevel_set_min_size: u32 = 8;
pub const xdg_toplevel_set_maximized: u32 = 9;
pub const xdg_toplevel_unset_maximized: u32 = 10;
pub const xdg_toplevel_set_fullscreen: u32 = 11;
pub const xdg_toplevel_unset_fullscreen: u32 = 12;
pub const xdg_toplevel_set_minimized: u32 = 13;

/// --- Estados do xdg_toplevel (enum `xdg_toplevel_state`) ---
pub const xdg_toplevel_state_maximized: u32 = 1;
pub const xdg_toplevel_state_fullscreen: u32 = 2;
pub const xdg_toplevel_state_resizing: u32 = 3;
pub const xdg_toplevel_state_activated: u32 = 4;

/// --- Formatos de wl_shm (`wl_shm.format`) ---
pub const wl_shm_format_argb8888: u32 = 0;
pub const wl_shm_format_xrgb8888: u32 = 1;

test "wl_argument layout matches wayland-util.h" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(wl_argument));
}
