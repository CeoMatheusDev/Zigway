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
const xkb = @import("xkb.zig");
const keysym = @import("../keysym.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");
const native = @import("../../core/native.zig");
const wakeup_mod = @import("../wakeup.zig");
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

/// Botao de ponteiro pendente (evento `pointer_button`).
const PendingButton = struct {
    button: types.MouseButton,
    pressed: bool,
};

/// Rolagem pendente (evento `scroll`).
const PendingScroll = struct {
    dx: f32,
    dy: f32,
};

/// Tecla pendente (evento `key_down`/`key_up`).
const PendingKey = struct {
    key: types.Key,
    pressed: bool,
    /// Repeticao automatica (o Wayland nao informa: o compositor
    /// reenvia o evento com a tecla ja pressionada).
    repeat: bool = false,
};

/// Tecla fisica pendente (evento `raw_key`).
const PendingRawKey = struct {
    /// Keycode XKB (evdev + 8).
    scancode: u32,
    pressed: bool,
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
    /// Tamanho do buffer atual (o que o compositor confirmou), em pixels
    /// fisicos (ja inclui a escala).
    width: u32 = 0,
    height: u32 = 0,
    /// Tamanho logico da superficie (unidades do compositor).
    logical_width: u32 = 0,
    logical_height: u32 = 0,
    /// Escala da janela (fracao). 1/1 = 100%.
    scale: types.Scale = .identity,
    /// Escala preferida mudando (aguardando o evento do compositor).
    pending_scale: ?types.Scale = null,
    /// Objetos de escala/viewport desta superficie.
    fractional_scale: ?*api.wl_proxy = null,
    viewport: ?*api.wl_proxy = null,
    /// Restricao ativa: o objeto e a ultima restricao pedida.
    locked_pointer: ?*api.wl_proxy = null,
    confined_pointer: ?*api.wl_proxy = null,
    /// Restricao confirmada pelo compositor (o estado efetivo).
    confirmed_constraint: types.PointerConstraint = .none,
    /// Regiao de confinamento pedida (coordenadas logicas).
    constraint_region: ?types.ConstraintRegion = null,
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

/// Callbacks do `wl_keyboard` (wayland-client-core.h).
const KeyboardListener = extern struct {
    keymap: *const fn (?*anyopaque, ?*api.wl_proxy, u32, i32, u32) callconv(.c) void,
    enter: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?*anyopaque) callconv(.c) void,
    key: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    modifiers: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: *const fn (?*anyopaque, ?*api.wl_proxy, i32, i32) callconv(.c) void,
};

/// Callbacks do `wl_pointer` (wayland-client-core.h)./// As coordenadas e o eixo sao `wl_fixed_t` (int32 em ponto fixo 24.8).
const PointerListener = extern struct {
    enter: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?*anyopaque, i32, i32) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?*anyopaque) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*api.wl_proxy, u32, i32, i32) callconv(.c) void,
    button: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, u32, u32) callconv(.c) void,
    axis: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, i32) callconv(.c) void,
    frame: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    axis_source: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
    axis_stop: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32) callconv(.c) void,
    axis_discrete: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, i32) callconv(.c) void,
    axis_value120: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, i32) callconv(.c) void,
    axis_relative_direction: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32, u32) callconv(.c) void,
    warp: *const fn (?*anyopaque, ?*api.wl_proxy, u32, i32, i32) callconv(.c) void,
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

/// Callbacks do `wl_data_device` (wayland-client-core.h).
const DataDeviceListener = extern struct {
    data_offer: *const fn (?*anyopaque, ?*api.wl_proxy, ?*api.wl_proxy) callconv(.c) void,
    enter: *const fn (?*anyopaque, ?*api.wl_proxy, u32, ?*api.wl_proxy, i32, i32, ?*api.wl_proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*api.wl_proxy, u32, i32, i32) callconv(.c) void,
    drop: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    selection: *const fn (?*anyopaque, ?*api.wl_proxy, ?*api.wl_proxy) callconv(.c) void,
};

/// Callbacks do `wl_data_offer`.
const DataOfferListener = extern struct {
    offer: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    source_actions: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `wl_data_source`.
const DataSourceListener = extern struct {
    target: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    send: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8, c_int) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    dnd_drop_performed: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    dnd_finished: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `zwp_text_input_v3` (text-input-unstable-v3.xml).
const TextInputListener = extern struct {
    enter: *const fn (?*anyopaque, ?*api.wl_proxy, ?*api.wl_proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*api.wl_proxy, ?*api.wl_proxy) callconv(.c) void,
    preedit_string: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8, c_int, c_int) callconv(.c) void,
    commit_string: *const fn (?*anyopaque, ?*api.wl_proxy, ?[*:0]const u8) callconv(.c) void,
    delete_surrounding_text: *const fn (?*anyopaque, ?*api.wl_proxy, u32, u32) callconv(.c) void,
    done: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `wp_fractional_scale_v1`.
const FractionalScaleListener = extern struct {
    preferred_scale: *const fn (?*anyopaque, ?*api.wl_proxy, u32) callconv(.c) void,
};

/// Callbacks do `zwp_relative_pointer_v1`.
const RelativePointerListener = extern struct {
    relative_motion: *const fn (
        ?*anyopaque,
        ?*api.wl_proxy,
        u32,
        i32,
        i32,
        i32,
        i32,
    ) callconv(.c) void,
};

/// Callbacks do `zwp_locked_pointer_v1`.
const LockedPointerListener = extern struct {
    locked: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    unlocked: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
};

/// Callbacks do `zwp_confined_pointer_v1`.
const ConfinedPointerListener = extern struct {
    confined: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
    unconfined: *const fn (?*anyopaque, ?*api.wl_proxy) callconv(.c) void,
};

/// Listeners do protocolo (endereco estavel: a libwayland guarda o
/// ponteiro).
const Listeners = struct {
    registry: RegistryListener,
    output: OutputListener,
    seat: SeatListener,
    pointer: PointerListener,
    keyboard: KeyboardListener,
    shm: ShmListener,
    surface: SurfaceListener,
    wm_base: WmBaseListener,
    xdg_surface: XdgSurfaceListener,
    xdg_toplevel: XdgToplevelListener,
    data_device: DataDeviceListener,
    data_offer: DataOfferListener,
    data_source: DataSourceListener,
    text_input: TextInputListener,
    fractional_scale: FractionalScaleListener,
    relative_pointer: RelativePointerListener,
    locked_pointer: LockedPointerListener,
    confined_pointer: ConfinedPointerListener,
};

/// Estado mutavel do backend (heap, endereco estavel para os callbacks).
const State = struct {
    allocator: std.mem.Allocator,
    outputs: std.ArrayList(OutputState) = .empty,
    seat: ?*api.wl_proxy = null,
    /// Versao negociada do seat (define a versao do ponteiro).
    seat_version: u32 = 0,
    /// Capacidades do seat (bits de `wl_seat_capability_*`).
    seat_capabilities: u32 = 0,
    /// Tema de cursor carregado (libwayland-cursor). null se indisponivel.
    cursor_theme: ?*api.wl_cursor_theme = null,
    /// Biblioteca de cursors carregada (dono do DynLib).
    cursor_lib: ?api.CursorLib = null,
    /// Superficie usada para o cursor.
    cursor_surface: ?*api.wl_proxy = null,
    /// Serial do ultimo wl_pointer.enter (necessario para set_cursor).
    last_pointer_serial: u32 = 0,
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
    /// Ponteiro do seat (criado quando o compositor anuncia a
    /// capacidade).
    pointer: ?*api.wl_proxy = null,
    pointer_version: u32 = 0,
    /// Teclado do seat (criado quando o compositor anuncia a
    /// capacidade).
    keyboard: ?*api.wl_proxy = null,
    keyboard_version: u32 = 0,
    /// Keymap XKB (null quando a libxkbcommon nao esta disponivel).
    keymap: ?xkb.Keymap = null,
    /// Superficie com o foco do teclado.
    keyboard_surface: ?*api.wl_proxy = null,
    /// Modificadores pressionados (mascara XKB).
    keyboard_modifiers: u32 = 0,
    /// Tecla pendente (evento `key_down`/`key_up`).
    pending_key: ?PendingKey = null,
    /// Tecla fisica pendente (evento `raw_key`): o keycode XKB
    /// (evdev + 8, como o keycode do X11).
    pending_raw_key: ?PendingRawKey = null,
    /// Foco do teclado pendente (evento `focus`).
    pending_focus: ?bool = null,
    /// Superficie com o foco do ponteiro (a que recebe os eventos).
    pointer_surface: ?*api.wl_proxy = null,
    /// Ultima posicao do ponteiro (coordenadas da superficie).
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    /// Eixo acumulado do frame atual (roda).
    axis_vertical: f32 = 0,
    axis_horizontal: f32 = 0,
    /// Valor do eixo em 120avos de grau (quando o compositor envia).
    axis_vertical_120: ?i32 = null,
    axis_horizontal_120: ?i32 = null,
    /// Passos discretos do eixo (quando o compositor envia).
    axis_vertical_discrete: ?i32 = null,
    axis_horizontal_discrete: ?i32 = null,
    /// Eventos de entrada pendentes (convertidos em eventos da
    /// plataforma no `poll`).
    pending_move: bool = false,
    pending_button: ?PendingButton = null,
    pending_scroll: ?PendingScroll = null,
    /// Descritores de arquivo ja enviados ao compositor via SCM_RIGHTS:
    /// so podem ser fechados depois que a requisicao foi enviada (flush).
    pending_fds: std.ArrayList(i32) = .empty,
    /// Um output mudou (modo/escala/posicao): o aplicativo precisa
    /// reconsultar `displays()`.
    pending_display_change: bool = false,
    /// A escala de uma janela mudou (publicar `scale_changed`).
    pending_scale_changed: bool = false,
    /// Gerenciador de data device (clipboard do protocolo Wayland).
    data_device_manager: ?*api.wl_proxy = null,
    data_device_manager_version: u32 = 0,
    data_device: ?*api.wl_proxy = null,
    data_device_version: u32 = 0,
    /// Texto publicado na selecao (UTF-8) e o source correspondente.
    clipboard_text: ?[]u8 = null,
    clipboard_source: ?*api.wl_proxy = null,
    /// Offer da selecao atual (evento `selection`) e seus tipos MIME.
    selection_offer: ?*api.wl_proxy = null,
    selection_mimes: std.ArrayList([64]u8) = .empty,
    /// Pipe de escrita pendente (o compositor pediu os dados).
    pending_send_fd: ?c_int = null,
    /// Regioes de confinamento criadas (destruidas com a janela).
    regions: std.ArrayList(*api.wl_proxy) = .empty,
    /// Gerenciador de movimento relativo.
    relative_pointer_manager: ?*api.wl_proxy = null,
    /// Objeto de movimento relativo (ligado ao wl_pointer do seat).
    relative_pointer: ?*api.wl_proxy = null,
    relative_pointer_manager_version: u32 = 0,
    /// Gerenciador de restricoes de ponteiro (lock/confinamento).
    pointer_constraints_manager: ?*api.wl_proxy = null,
    pointer_constraints_manager_version: u32 = 0,
    /// Gerenciador de escala fracionaria (wp_fractional_scale_manager_v1).
    fractional_scale_manager: ?*api.wl_proxy = null,
    fractional_scale_manager_version: u32 = 0,
    /// Viewporter (wp_viewporter), necessario para escala fracionaria.
    viewporter: ?*api.wl_proxy = null,
    viewporter_version: u32 = 0,
    /// Gerenciador de entrada de texto (zwp_text_input_manager_v3).
    text_input_manager: ?*api.wl_proxy = null,
    text_input_manager_version: u32 = 0,
    /// Contexto de entrada de texto do seat.
    text_input: ?*api.wl_proxy = null,
    /// Superficie que tem o foco de entrada de texto.
    text_input_surface: ?*api.wl_proxy = null,
    /// Texto em composicao (preedit) e uma composicao em andamento.
    composition_text: []u8 = &.{},
    composition_active: bool = false,
    /// Contexto do despacho corrente (valido apenas durante o poll).
    poll_reg: ?*registry.Registry = null,
    poll_queue: ?*events.EventQueue = null,
    poll_input: ?*input.InputState = null,
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
        .data_device = .{
            .data_offer = onDeviceDataOffer,
            .enter = onDeviceEnter,
            .leave = onDeviceLeave,
            .motion = onDeviceMotion,
            .drop = onDeviceDrop,
            .selection = onDeviceSelection,
        },
        .data_offer = .{
            .offer = onOfferMime,
            .source_actions = onOfferSourceActions,
            .action = onOfferAction,
        },
        .data_source = .{
            .target = onSourceTarget,
            .send = onSourceSend,
            .cancelled = onSourceCancelled,
            .dnd_drop_performed = onSourceDndDropPerformed,
            .dnd_finished = onSourceDndFinished,
            .action = onSourceAction,
        },
        .fractional_scale = .{
            .preferred_scale = onFractionalScalePreferred,
        },
        .relative_pointer = .{
            .relative_motion = onRelativeMotion,
        },
        .locked_pointer = .{
            .locked = onPointerLocked,
            .unlocked = onPointerUnlocked,
        },
        .confined_pointer = .{
            .confined = onPointerConfined,
            .unconfined = onPointerUnconfined,
        },
        .text_input = .{
            .enter = onTextInputEnter,
            .leave = onTextInputLeave,
            .preedit_string = onTextInputPreedit,
            .commit_string = onTextInputCommit,
            .delete_surrounding_text = onTextInputDeleteSurrounding,
            .done = onTextInputDone,
        },
        .pointer = .{
            .enter = onPointerEnter,
            .leave = onPointerLeave,
            .motion = onPointerMotion,
            .button = onPointerButton,
            .axis = onPointerAxis,
            .frame = onPointerFrame,
            .axis_source = onPointerAxisSource,
            .axis_stop = onPointerAxisStop,
            .axis_discrete = onPointerAxisDiscrete,
            .axis_value120 = onPointerAxisValue120,
            .axis_relative_direction = onPointerAxisRelativeDirection,
            .warp = onPointerWarp,
        },
        .keyboard = .{
            .keymap = onKeyboardKeymap,
            .enter = onKeyboardEnter,
            .leave = onKeyboardLeave,
            .key = onKeyboardKey,
            .modifiers = onKeyboardModifiers,
            .repeat_info = onKeyboardRepeatInfo,
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
            self.seat_version = bind_version;
            self.ensureDataDevice();
            self.ensureTextInput();
        } else if (std.mem.eql(u8, iface, api.interface_wl_compositor)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.compositor_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.compositor_interface) orelse return;
            self.compositor = proxy;
            self.compositor_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_zwp_relative_pointer_manager_v1)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.relative_pointer_manager_v1_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.relative_pointer_manager_v1_interface) orelse return;
            self.relative_pointer_manager = proxy;
            self.relative_pointer_manager_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_zwp_pointer_constraints_manager_v1)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.pointer_constraints_manager_v1_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.pointer_constraints_manager_v1_interface) orelse return;
            self.pointer_constraints_manager = proxy;
            self.pointer_constraints_manager_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_wp_fractional_scale_manager_v1)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.fractional_scale_manager_v1_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.fractional_scale_manager_v1_interface) orelse return;
            self.fractional_scale_manager = proxy;
            self.fractional_scale_manager_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_wp_viewporter)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.viewporter_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.viewporter_interface) orelse return;
            self.viewporter = proxy;
            self.viewporter_version = bind_version;
        } else if (std.mem.eql(u8, iface, api.interface_zwp_text_input_manager_v3)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.text_input_manager_v3_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.text_input_manager_v3_interface) orelse return;
            self.text_input_manager = proxy;
            self.text_input_manager_version = bind_version;
            self.ensureTextInput();
        } else if (std.mem.eql(u8, iface, api.interface_wl_data_device_manager)) {
            const bind_version = @min(version, @as(u32, @intCast(protocol.data_device_manager_interface.version)));
            const proxy = bindGlobal(lib, registry_proxy, name, interface, bind_version, &protocol.data_device_manager_interface) orelse return;
            self.data_device_manager = proxy;
            self.data_device_manager_version = bind_version;
            self.ensureDataDevice();
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
            // O `ping` precisa de listener: sem `pong` o compositor
            // considera o cliente travado e encerra a conexao.
            lib.proxy_add_listener(
                proxy,
                @ptrCast(&self.listeners.wm_base),
                @ptrCast(self),
            );
            self.wm_base = proxy;
            self.wm_base_version = bind_version;
        }
    }

    /// Slot da janela associada a uma superficie.
    fn windowSlotBySurface(self: *const State, surface: *api.wl_proxy) ?u32 {
        for (self.windows.items) |entry| {
            if (entry.surface == surface) return entry.slot;
        }
        return null;
    }

    /// Janela que tem o foco de entrada de texto (null se nenhuma).
    fn textInputWindowId(self: *const State) ?types.WindowId {
        const surface = self.text_input_surface orelse return null;
        const reg = self.poll_reg orelse return null;
        const slot = self.windowSlotBySurface(surface) orelse return null;
        if (slot >= reg.slots.items.len) return null;
        if (!reg.slots.items[slot].occupied) return null;
        return reg.idOf(slot);
    }

    /// Cria um `wl_region` (coordenadas logicas da superficie).
    fn createRegion(self: *State, r: types.ConstraintRegion) ?*api.wl_proxy {
        const compositor = self.compositor orelse return null;
        const region = self.symbols.proxy_marshal_flags(
            compositor,
            api.wl_compositor_create_region,
            &protocol.region_interface,
            self.compositor_version,
            0,
            @as(?*anyopaque, null),
        ) orelse return null;
        // `wl_region.add` (x, y, width, height).
        _ = self.symbols.proxy_marshal_flags(
            region,
            api.wl_region_add,
            null,
            0,
            0,
            @as(i32, r.x),
            @as(i32, r.y),
            @as(i32, @intCast(r.width)),
            @as(i32, @intCast(r.height)),
        );
        return region;
    }

    /// Libera a restricao de ponteiro ativa da janela.
    fn releaseConstraint(self: *State, index: usize) void {
        const entry = &self.windows.items[index];
        if (entry.locked_pointer) |proxy| {
            requestNoArgs(&self.symbols, proxy, api.zwp_locked_pointer_v1_destroy);
            self.symbols.proxy_destroy(proxy);
            entry.locked_pointer = null;
        }
        if (entry.confined_pointer) |proxy| {
            requestNoArgs(&self.symbols, proxy, api.zwp_confined_pointer_v1_destroy);
            self.symbols.proxy_destroy(proxy);
            entry.confined_pointer = null;
        }
        entry.confirmed_constraint = .none;
        entry.constraint_region = null;
    }

    /// Cria (sob demanda) o objeto de movimento relativo.
    ///
    /// O objeto e ligado ao `wl_pointer` do seat (nao a uma superficie):
    /// `get_relative_pointer` recebe o ponteiro. O evento nao identifica
    /// a janela, entao o texto usa a superficie sob o ponteiro.
    fn ensureRelativePointer(self: *State) void {
        if (self.relative_pointer != null) return;
        const manager = self.relative_pointer_manager orelse return;
        const pointer = self.pointer orelse return;
        const proxy = self.symbols.proxy_marshal_flags(
            manager,
            api.zwp_relative_pointer_manager_v1_get_relative_pointer,
            &protocol.relative_pointer_interface,
            self.relative_pointer_manager_version,
            0,
            @as(?*anyopaque, null),
            @as(?*anyopaque, @ptrCast(pointer)),
        ) orelse return;
        self.symbols.proxy_add_listener(
            proxy,
            @ptrCast(&self.listeners.relative_pointer),
            @ptrCast(self),
        );
        self.relative_pointer = proxy;
    }

    /// Cria os objetos de escala da superficie (escala fracionaria e
    /// viewport). Sem `wp_viewporter` a escala fracionaria nao pode ser
    /// aplicada (o compositor nao consegue escalar o buffer).
    fn ensureScaleObjects(self: *State, index: usize) void {
        const entry = &self.windows.items[index];
        if (self.fractional_scale_manager) |manager| {
            if (entry.fractional_scale == null) {
                const proxy = self.symbols.proxy_marshal_flags(
                    manager,
                    api.wp_fractional_scale_manager_v1_get_fractional_scale,
                    &protocol.fractional_scale_v1_interface,
                    self.fractional_scale_manager_version,
                    0,
                    @as(?*anyopaque, null),
                    @as(?*anyopaque, @ptrCast(entry.surface)),
                );
                if (proxy) |p| {
                    self.symbols.proxy_add_listener(
                        p,
                        @ptrCast(&self.listeners.fractional_scale),
                        @ptrCast(self),
                    );
                    entry.fractional_scale = p;
                }
            }
        }
        if (self.viewporter) |viewporter| {
            if (entry.viewport == null) {
                const proxy = self.symbols.proxy_marshal_flags(
                    viewporter,
                    api.wp_viewporter_get_viewport,
                    &protocol.viewport_interface,
                    self.viewporter_version,
                    0,
                    @as(?*anyopaque, null),
                    @as(?*anyopaque, @ptrCast(entry.surface)),
                );
                entry.viewport = proxy;
            }
        }
    }

    /// Cria o `zwp_text_input_v3` (precisa do gerenciador e do seat).
    fn ensureTextInput(self: *State) void {
        if (self.text_input != null) return;
        const manager = self.text_input_manager orelse return;
        const seat = self.seat orelse return;
        const proxy = self.symbols.proxy_marshal_flags(
            manager,
            api.zwp_text_input_manager_v3_get_text_input,
            &protocol.text_input_v3_interface,
            self.text_input_manager_version,
            0,
            @as(?*anyopaque, null),
            @as(?*anyopaque, @ptrCast(seat)),
        ) orelse return;
        self.symbols.proxy_add_listener(
            proxy,
            @ptrCast(&self.listeners.text_input),
            @ptrCast(self),
        );
        self.text_input = proxy;
    }

    /// Cria o `wl_data_device` (precisa do gerenciador e do seat).
    fn ensureDataDevice(self: *State) void {
        if (self.data_device != null) return;
        const manager = self.data_device_manager orelse return;
        const seat = self.seat orelse return;
        const proxy = self.symbols.proxy_marshal_flags(
            manager,
            api.wl_data_device_manager_get_data_device,
            &protocol.data_device_interface,
            self.data_device_manager_version,
            0,
            // A assinatura e "no": primeiro o slot do new_id, depois o seat.
            @as(?*anyopaque, null),
            @as(?*anyopaque, @ptrCast(seat)),
        ) orelse return;
        self.symbols.proxy_add_listener(
            proxy,
            @ptrCast(&self.listeners.data_device),
            @ptrCast(self),
        );
        self.data_device = proxy;
    }

    /// Cria um `wl_data_source` com os tipos MIME de texto.
    fn createDataSource(self: *State) ?*api.wl_proxy {
        const manager = self.data_device_manager orelse return null;
        const source = self.symbols.proxy_marshal_flags(
            manager,
            api.wl_data_device_manager_create_data_source,
            &protocol.data_source_interface,
            self.data_device_manager_version,
            0,
            @as(?*anyopaque, null),
        ) orelse return null;
        self.symbols.proxy_add_listener(
            source,
            @ptrCast(&self.listeners.data_source),
            @ptrCast(self),
        );
        for ([_][:0]const u8{ "text/plain;charset=utf-8", "text/plain" }) |mime| {
            _ = self.symbols.proxy_marshal_flags(
                source,
                api.wl_data_source_offer,
                null,
                0,
                0,
                mime.ptr,
            );
        }
        return source;
    }

    /// Publica o source como selecao atual.
    fn setSelection(self: *State, source: *api.wl_proxy) void {
        const device = self.data_device orelse return;
        _ = self.symbols.proxy_marshal_flags(
            device,
            api.wl_data_device_set_selection,
            null,
            0,
            0,
            @as(?*anyopaque, @ptrCast(source)),
            @as(u32, 0),
        );
    }

    /// Tipo MIME preferido da selecao atual (string terminada em NUL).
    fn selectionMime(self: *const State) ?[*:0]const u8 {
        for (self.selection_mimes.items) |*mime| {
            if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return @ptrCast(mime);
        }
        for (self.selection_mimes.items) |*mime| {
            if (std.mem.eql(u8, mime, "text/plain")) return @ptrCast(mime);
        }
        return null;
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

    /// Cria o `wl_pointer` do seat (o compositor anuncia a capacidade
    /// do ponteiro).
    fn bindPointer(self: *State) void {
        const seat = self.seat orelse return;
        const version = @min(
            self.seat_version,
            @as(u32, @intCast(protocol.pointer_interface.version)),
        );
        const pointer = self.symbols.proxy_marshal_flags(
            seat,
            api.wl_seat_get_pointer,
            &protocol.pointer_interface,
            version,
            0,
            @as(?*anyopaque, null),
        ) orelse return;
        self.symbols.proxy_add_listener(
            pointer,
            @ptrCast(&self.listeners.pointer),
            @ptrCast(self),
        );
        self.pointer = pointer;
        self.pointer_version = version;
    }

    /// Cria o `wl_keyboard` do seat (o compositor anuncia a
    /// capacidade do teclado).
    fn bindKeyboard(self: *State) void {
        const seat = self.seat orelse return;
        const version = @min(
            self.seat_version,
            @as(u32, @intCast(protocol.keyboard_interface.version)),
        );
        const keyboard = self.symbols.proxy_marshal_flags(
            seat,
            api.wl_seat_get_keyboard,
            &protocol.keyboard_interface,
            version,
            0,
            @as(?*anyopaque, null),
        ) orelse return;
        self.symbols.proxy_add_listener(
            keyboard,
            @ptrCast(&self.listeners.keyboard),
            @ptrCast(self),
        );
        self.keyboard = keyboard;
        self.keyboard_version = version;
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

        // Escala: o compositor pode ter anunciado uma escala nova
        // (wp_fractional_scale_v1) depois do ultimo configure.
        if (entry.pending_scale) |new_scale| {
            entry.pending_scale = null;
            if (!entry.scale.eql(new_scale)) {
                entry.scale = new_scale;
                self.pending_scale_changed = true;
            }
        }

        // Tamanho logico (unidades da superficie) e tamanho fisico do
        // buffer (logico * escala).
        const logical_width = if (entry.pending_width > 0) entry.pending_width else entry.logical_width;
        const logical_height = if (entry.pending_height > 0) entry.pending_height else entry.logical_height;
        if (logical_width == 0 or logical_height == 0) return;
        entry.logical_width = logical_width;
        entry.logical_height = logical_height;
        const physical = entry.scale.applyToSize(.{ .width = logical_width, .height = logical_height });
        const width = physical.width;
        const height = physical.height;

        if (!entry.visible) {
            // Janela oculta: sem buffer a superficie fica desmapeada.
            requestAttach(&self.symbols, entry.surface, null);
            requestNoArgs(&self.symbols, entry.surface, api.wl_surface_commit);
            return;
        }

        const resized = entry.buffer == null or entry.width != width or entry.height != height;
        self.attachBuffer(index, width, height) catch return;
        // Com escala fracionaria o viewport mapeia o buffer (fisico) no
        // tamanho logico da superficie.
        if (entry.viewport) |viewport| {
            requestViewportDestination(&self.symbols, viewport, logical_width, logical_height);
            requestViewportSource(&self.symbols, viewport, width, height);
        }
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

/// `wp_viewport.set_destination` (tamanho logico da superficie).
fn requestViewportDestination(
    lib: *api.Symbols,
    proxy: *api.wl_proxy,
    width: u32,
    height: u32,
) void {
    _ = lib.proxy_marshal_flags(
        proxy,
        api.wp_viewport_set_destination,
        null,
        0,
        0,
        @as(i32, @intCast(width)),
        @as(i32, @intCast(height)),
    );
}

/// `wp_viewport.set_source` (origem no buffer, em pixels).
///
/// A origem e o retangulo do buffer que alimenta o destino. O protocolo
/// aceita (-1,-1,-1,-1) para "sem recorte", mas nao aceita (-1,-1) com
/// tamanho valido (erro `bad_value`).
fn requestViewportSource(
    lib: *api.Symbols,
    proxy: *api.wl_proxy,
    width: u32,
    height: u32,
) void {
    _ = lib.proxy_marshal_flags(
        proxy,
        api.wp_viewport_set_source,
        null,
        0,
        0,
        @as(i32, 0),
        @as(i32, 0),
        @as(i32, @intCast(width)),
        @as(i32, @intCast(height)),
    );
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
    /// Descritor de wakeup: outra thread pode acordar o loop de eventos.
    wakeup_pipe: wakeup_mod.Wakeup = .{},

    pub fn init(allocator: std.mem.Allocator) !Backend {
        var lib = api.Lib.load() orelse return error.UnsupportedBackend;
        errdefer lib.deinit();
        var cursor_lib = api.CursorLib.load();
        errdefer if (cursor_lib) |*cl| cl.deinit();
        const display = lib.symbols.display_connect(null) orelse return error.NoDisplay;
        errdefer lib.symbols.display_disconnect(display);

        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .symbols = lib.symbols, .cursor_lib = cursor_lib };

        // Keymap XKB: a libxkbcommon e opcional (sem ela o backend
        // funciona, mas o teclado nao entrega teclas).
        state.keymap = xkb.Keymap.init() catch null;

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

        // As propriedades iniciais dos outputs nao sao uma "mudanca":
        // o flag e limpo depois dos roundtrips.
        // Roundtrip: recebe os globals (wl_output, wl_seat, ...).
        if (lib.symbols.display_roundtrip(display) < 0) return error.ConnectionFailed;

        // Segundo roundtrip: os binds feitos acima recebem agora os
        // eventos de propriedade dos outputs (geometry/mode/scale), do
        // seat (capabilities) e do shm (format).
        if (lib.symbols.display_roundtrip(display) < 0) return error.ConnectionFailed;

        // As propriedades iniciais nao contam como mudanca de display.
        state.pending_display_change = false;

        var wake = wakeup_mod.Wakeup.init() catch wakeup_mod.Wakeup{};
        errdefer wake.deinit();

        return .{
            .allocator = allocator,
            .lib = lib,
            .display = display,
            .registry = registry_proxy,
            .state = state,
            .wakeup_pipe = wake,
        };
    }

    /// Destruicao do backend.
    ///
    /// A ordem importa: tudo que ainda fala com o servidor precisa ser
    /// destruido ANTES de `wl_display_disconnect` (destruir objetos
    /// depois do disconnect usa proxies mortos e a libwayland-cursor
    /// chega a segfaultar). Dentro do teardown, a dependencia tambem
    /// importa: a superficie do cursor antes do tema (o tema destroi os
    /// buffers que a superficie usa) e o tema antes do `wl_shm` (o tema
    /// cria os pools a partir dele).
    pub fn deinit(self: *Backend) void {
        const state = self.state;
        const lib = &self.lib.symbols;

        // 1) Janelas (superficies/xdg) antes de qualquer global.
        while (state.windows.items.len > 0) {
            self.destroyWindowEntry(0);
        }
        state.windows.deinit(self.allocator);
        state.closePendingFds();
        state.pending_fds.deinit(self.allocator);
        if (state.keymap) |*keymap| keymap.deinit();

        // 2) Cursor: superficie (libera o buffer) e depois o tema (que
        //    destroi os pools do `wl_shm`).
        if (state.cursor_surface) |surface| {
            lib.proxy_destroy(surface);
            state.cursor_surface = null;
        }
        if (state.cursor_theme) |theme| {
            if (state.cursor_lib) |*cl| cl.theme_destroy(theme);
            state.cursor_theme = null;
        }

        // 3) Demais objetos do protocolo.
        for (state.outputs.items) |out| lib.proxy_destroy(out.proxy);
        state.outputs.deinit(self.allocator);
        state.selection_mimes.deinit(self.allocator);
        if (state.clipboard_text) |text| self.allocator.free(text);
        state.clipboard_text = null;
        if (state.selection_offer) |offer| lib.proxy_destroy(offer);
        state.selection_offer = null;
        if (state.clipboard_source) |source| lib.proxy_destroy(source);
        state.clipboard_source = null;
        if (state.data_device) |device| lib.proxy_destroy(device);
        state.data_device = null;
        if (state.data_device_manager) |manager| lib.proxy_destroy(manager);
        state.data_device_manager = null;
        for (state.regions.items) |region| {
            requestNoArgs(lib, region, api.wl_region_destroy);
            lib.proxy_destroy(region);
        }
        state.regions.deinit(self.allocator);
        if (state.relative_pointer) |proxy| {
            requestNoArgs(lib, proxy, api.zwp_relative_pointer_v1_destroy);
            lib.proxy_destroy(proxy);
            state.relative_pointer = null;
        }
        if (state.relative_pointer_manager) |manager| lib.proxy_destroy(manager);
        state.relative_pointer_manager = null;
        if (state.pointer_constraints_manager) |manager| lib.proxy_destroy(manager);
        state.pointer_constraints_manager = null;
        if (state.text_input) |text_input| lib.proxy_destroy(text_input);
        state.text_input = null;
        if (state.text_input_manager) |manager| lib.proxy_destroy(manager);
        state.text_input_manager = null;
        if (state.pointer) |pointer| lib.proxy_destroy(pointer);
        state.pointer = null;
        if (state.keyboard) |keyboard| lib.proxy_destroy(keyboard);
        state.keyboard = null;
        if (state.seat) |seat| lib.proxy_destroy(seat);
        state.seat = null;
        if (state.shm) |shm| lib.proxy_destroy(shm);
        state.shm = null;
        if (state.wm_base) |wm_base| lib.proxy_destroy(wm_base);
        state.wm_base = null;
        if (state.compositor) |compositor| lib.proxy_destroy(compositor);
        state.compositor = null;

        // 4) Registry e, por ultimo, a conexao.
        lib.proxy_destroy(self.registry);
        lib.display_disconnect(self.display);

        // 5) Bibliotecas dlopen (apos a conexao: as libs nao podem
        //    receber callbacks de um display morto).
        if (state.cursor_lib) |*cl| cl.deinit();
        state.cursor_lib = null;
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

    /// Publica texto (UTF-8) na selecao do clipboard do protocolo
    /// Wayland (`wl_data_device.set_selection`).
    /// O Wayland suporta clipboard, cursor do sistema e entrada de texto
    /// (via `zwp_text_input_v3`); nao suporta posicionamento absoluto,
    /// resize pedido, foco pedido, captura de ponteiro nem modos de
    /// video (o compositor decide).
    pub fn capabilities(self: *const Backend) types.Capabilities {
        const st = self.state;
        return .{
            .absolute_positioning = false,
            .resize_request = false,
            .focus_request = false,
            .clipboard = st.data_device != null,
            .text_input_ime = st.text_input != null,
            .surrounding_text = st.text_input != null,
            .system_cursor = st.cursor_lib != null,
            .pointer_capture = false,
            .pointer_relative = st.relative_pointer_manager != null,
            .pointer_lock = st.pointer_constraints_manager != null,
            .pointer_confinement = st.pointer_constraints_manager != null,
            .fractional_scale = st.fractional_scale_manager != null and
                st.viewporter != null,
            .dpi_per_monitor = false,
            .video_modes = false,
            .seat = st.seat != null,
        };
    }

    /// Texto em composicao (preedit) da janela.
    pub fn compositionText(self: *const Backend, reg: *registry.Registry, id: types.WindowId) ?[]const u8 {
        _ = reg;
        const st = self.state;
        if (!st.composition_active) return null;
        if (st.composition_text.len == 0) return null;
        _ = id;
        return st.composition_text;
    }

    /// Escala da janela (fracao). Vem do `wp_fractional_scale_v1` quando
    /// o compositor suporta; caso contrario 1:1.
    pub fn windowScale(self: *const Backend, reg: *const registry.Registry, id: types.WindowId) types.Scale {
        const st = self.state;
        const slot = reg.slotOf(id) orelse return .identity;
        for (st.windows.items) |entry| {
            if (entry.slot != slot) continue;
            return entry.scale;
        }
        return .identity;
    }

    /// Tamanho fisico do buffer da janela (pixels da tela).
    pub fn windowBufferSize(self: *const Backend, reg: *const registry.Registry, id: types.WindowId) types.WindowSize {
        const st = self.state;
        const slot = reg.slotOf(id) orelse return .{ .width = 0, .height = 0 };
        for (st.windows.items) |entry| {
            if (entry.slot != slot) continue;
            return .{ .width = entry.width, .height = entry.height };
        }
        return .{ .width = 0, .height = 0 };
    }

    /// Escala do output (inteira, vinda de `wl_output.scale`).
    pub fn displayScale(self: *const Backend, id: types.DisplayId) types.Scale {
        const st = self.state;
        for (st.outputs.items, 0..) |out, i| {
            if (i != id.raw) continue;
            const scale: u32 = if (out.scale > 0) @intCast(out.scale) else 1;
            return .{ .numerator = scale, .denominator = 1 };
        }
        return .identity;
    }

    /// Informa ao IME o texto ao redor do cursor (o contexto textual).
    ///
    /// A plataforma nao guarda o texto: ela apenas repassa ao compositor,
    /// para que o IME possa sugerir correcoes. `cursor` e o deslocamento
    /// (em bytes UTF-8) do cursor dentro de `text`.
    pub fn setSurroundingText(
        self: *Backend,
        reg: *registry.Registry,
        id: types.WindowId,
        text: []const u8,
        cursor: u32,
    ) !void {
        _ = reg;
        _ = id;
        const st = self.state;
        const proxy = st.text_input orelse return error.NotImplemented;
        // O texto vive enquanto o pedido e enviado: a libwayland copia o
        // argumento durante o marshal.
        const owned = st.allocator.dupeZ(u8, text) catch return error.OutOfMemory;
        defer st.allocator.free(owned);
        _ = self.lib.symbols.proxy_marshal_flags(
            proxy,
            api.zwp_text_input_v3_set_surrounding_text,
            null,
            0,
            0,
            owned.ptr,
            @as(i32, @intCast(cursor)),
            @as(i32, @intCast(text.len)),
        );
        _ = self.lib.symbols.proxy_marshal_flags(
            proxy,
            api.zwp_text_input_v3_commit,
            null,
            0,
            0,
        );
    }

    /// Aplica uma restricao de ponteiro (lock ou confinamento).
    ///
    /// O protocolo e assincrono: o compositor confirma com
    /// `locked`/`confined` (evento `pointer_constraint`). A regiao do
    /// confinamento e em coordenadas **logicas** da superficie (o
    /// protocolo converte usando a escala da superficie).
    pub fn setPointerConstraint(
        self: *const Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        id: types.WindowId,
        constraint: types.PointerConstraint,
        region: ?types.ConstraintRegion,
    ) !void {
        const st = self.state;
        const slot = reg.slotOf(id) orelse return error.InvalidWindow;
        const index = st.windowIndexBySlot(slot) orelse return error.InvalidWindow;
        const entry = &st.windows.items[index];

        // Libera a restricao anterior.
        st.releaseConstraint(index);

        switch (constraint) {
            .none => {
                // O compositor nao envia `unlocked` quando o objeto e
                // destruido: a liberacao e confirmada localmente.
                entry.confirmed_constraint = .none;
                reg.slots.items[slot].pointer_constraint = .none;
                events.dispatch(queue, state, .{ .pointer_constraint = .{
                    .window = reg.idOf(slot),
                    .constraint = .none,
                } });
                return;
            },
            .lock => {
                const manager = st.pointer_constraints_manager orelse
                    return error.NotImplemented;
                // Argumentos: surface, pointer, region (null), lifetime.
                const pointer = st.pointer orelse return error.NotImplemented;
                const proxy = st.symbols.proxy_marshal_flags(
                    manager,
                    api.zwp_pointer_constraints_manager_v1_lock_pointer,
                    &protocol.locked_pointer_interface,
                    st.pointer_constraints_manager_version,
                    0,
                    @as(?*anyopaque, null),
                    @as(?*anyopaque, @ptrCast(entry.surface)),
                    @as(?*anyopaque, @ptrCast(pointer)),
                    @as(?*anyopaque, null),
                    api.zwp_pointer_constraint_lifetime_persistent,
                ) orelse return error.WindowStateFailed;
                st.symbols.proxy_add_listener(
                    proxy,
                    @ptrCast(&st.listeners.locked_pointer),
                    @ptrCast(st),
                );
                entry.locked_pointer = proxy;
            },
            .confine => {
                const manager = st.pointer_constraints_manager orelse
                    return error.NotImplemented;
                // A regiao e um `wl_region` (superficie local, logico).
                var region_proxy: ?*api.wl_proxy = null;
                if (region) |r| {
                    if (r.width == 0 or r.height == 0) return error.InvalidConfig;
                    region_proxy = st.createRegion(r) orelse return error.WindowStateFailed;
                }
                // Argumentos: surface, pointer, region, lifetime.
                const pointer = st.pointer orelse return error.NotImplemented;
                const proxy = st.symbols.proxy_marshal_flags(
                    manager,
                    api.zwp_pointer_constraints_manager_v1_confine_pointer,
                    &protocol.confined_pointer_interface,
                    st.pointer_constraints_manager_version,
                    0,
                    @as(?*anyopaque, null),
                    @as(?*anyopaque, @ptrCast(entry.surface)),
                    @as(?*anyopaque, @ptrCast(pointer)),
                    if (region_proxy) |r| @as(?*anyopaque, @ptrCast(r)) else @as(?*anyopaque, null),
                    api.zwp_pointer_constraint_lifetime_persistent,
                ) orelse return error.WindowStateFailed;
                if (region_proxy) |r| {
                    // O `wl_region` e destruido junto com a superficie.
                    st.regions.append(st.allocator, r) catch {};
                }
                st.symbols.proxy_add_listener(
                    proxy,
                    @ptrCast(&st.listeners.confined_pointer),
                    @ptrCast(st),
                );
                entry.confined_pointer = proxy;
                entry.constraint_region = region;
            },
        }
        // A confirmacao vem do compositor (evento `pointer_constraint`).
        entry.confirmed_constraint = .none;
    }

    /// Restricao de ponteiro confirmada (o estado efetivo).
    pub fn pointerConstraint(
        self: *const Backend,
        reg: *const registry.Registry,
        id: types.WindowId,
    ) types.PointerConstraint {
        const st = self.state;
        const slot = reg.slotOf(id) orelse return .none;
        const index = st.windowIndexBySlot(slot) orelse return .none;
        return st.windows.items[index].confirmed_constraint;
    }

    pub fn setClipboardText(self: *Backend, text: []const u8) !void {
        const st = self.state;
        if (st.data_device == null) return error.ClipboardFailed;
        const source = st.createDataSource() orelse return error.ClipboardFailed;
        if (st.clipboard_text) |old| st.allocator.free(old);
        st.clipboard_text = try st.allocator.dupe(u8, text);
        st.clipboard_source = source;
        st.setSelection(source);
        _ = st.symbols.display_flush(self.display);
    }

    /// Le o texto (UTF-8) da selecao atual do clipboard do protocolo
    /// Wayland. `null` quando nao ha selecao, nenhum tipo MIME de texto
    /// ou o compositor nao respondeu a tempo.
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
        const st = self.state;
        const offer = st.selection_offer orelse return null;
        const mime = st.selectionMime() orelse return null;

        // Pipe: o compositor escreve os dados na ponta de leitura.
        var fds: [2]c_int = undefined;
        if (api.pipe2(&fds, api.O_NONBLOCK) != 0) return null;
        // `accept` + `receive`: o compositor envia o fd pela conexao.
        _ = st.symbols.proxy_marshal_flags(
            offer,
            api.wl_data_offer_accept,
            null,
            0,
            0,
            @as(u32, 0),
            mime,
        );
        _ = st.symbols.proxy_marshal_flags(
            offer,
            api.wl_data_offer_receive,
            null,
            0,
            0,
            mime,
            @as(c_int, fds[1]),
        );
        _ = st.symbols.display_flush(self.display);
        // Fecha a ponta de escrita: o compositor tem a copia (SCM_RIGHTS).
        _ = api.close(fds[1]);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [4096]u8 = undefined;
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            const n = std.posix.read(fds[0], &buf) catch |err| switch (err) {
                error.WouldBlock => {
                    var pfds = [_]std.posix.pollfd{.{
                        .fd = fds[0],
                        .events = std.posix.POLL.IN,
                        .revents = 0,
                    }};
                    _ = std.posix.poll(&pfds, 10) catch {};
                    continue;
                },
                else => break,
            };
            if (n == 0) break; // EOF
            try out.appendSlice(allocator, buf[0..n]);
        }
        _ = api.close(fds[0]);

        st.symbols.proxy_destroy(offer);
        st.selection_offer = null;
        if (out.items.len == 0) return null;
        return try out.toOwnedSlice(allocator);
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

        // Objetos de escala da superficie (fracionaria + viewport).
        st.ensureScaleObjects(st.windows.items.len - 1);

        // Commit inicial: o compositor responde com `xdg_surface.configure`
        // (e `xdg_toplevel.configure`), que dispara a criacao do buffer.
        requestNoArgs(lib, surface, api.wl_surface_commit);
        _ = reg;
    }

    fn destroyWindowEntry(self: *Backend, index: usize) void {
        const st = self.state;
        const entry = &st.windows.items[index];
        const lib = &st.symbols;
        if (entry.fractional_scale) |proxy| {
            requestNoArgs(lib, proxy, api.wp_fractional_scale_v1_destroy);
            lib.proxy_destroy(proxy);
            entry.fractional_scale = null;
        }
        if (entry.viewport) |proxy| {
            requestNoArgs(lib, proxy, api.wp_viewport_destroy);
            lib.proxy_destroy(proxy);
            entry.viewport = null;
        }
        // A restricao de ponteiro e liberada junto com a janela.
        st.releaseConstraint(index);
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
    /// Carrega (sob demanda) o tema de cursor e a superficie que o
    /// compositor usa como cursor.
    fn ensureCursorTheme(self: *Backend) void {
        const st = self.state;
        if (st.cursor_theme != null) return;
        const cl = st.cursor_lib orelse return;
        const shm = self.state.shm orelse return;
        const shm_proxy: *api.wl_shm = @ptrCast(shm);
        const theme = cl.theme_load(null, 24, shm_proxy);
        if (theme) |t| st.cursor_theme = t;
    }

    /// Nome do cursor do tema correspondente a `types.Cursor`.
    fn cursorName(cursor: types.Cursor) [*:0]const u8 {
        return switch (cursor) {
            .default => "left_ptr",
            .text => "text",
            .crosshair => "crosshair",
            .hand => "hand2",
            .resize_horizontal => "size_hor",
            .resize_vertical => "size_ver",
            .resize_all => "size_all",
            .not_allowed => "not-allowed",
            .wait => "wait",
        };
    }

    /// Handle nativo (wl_display/wl_surface) ainda nao exposto no Wayland.
    pub fn nativeHandle(self: *Backend, reg: *registry.Registry, slot: u32) !native.NativeHandle {
        _ = self;
        _ = reg;
        _ = slot;
        return error.NotImplemented;
    }

    pub fn setCursor(self: *Backend, reg: *registry.Registry, slot: u32, cursor: types.Cursor) !void {
        _ = reg;
        _ = slot;
        const st = self.state;
        const pointer = st.pointer orelse return error.NotImplemented;
        const serial = st.last_pointer_serial;
        if (serial == 0) return error.CursorCreationFailed;
        self.ensureCursorTheme();
        const theme = st.cursor_theme orelse return error.CursorCreationFailed;
        const cl = st.cursor_lib orelse return error.CursorCreationFailed;
        const cursor_name = cursorName(cursor);
        const wl_cursor = cl.theme_get_cursor(theme, cursor_name) orelse
            return error.CursorCreationFailed;
        if (wl_cursor.image_count == 0) return error.CursorCreationFailed;
        const image = wl_cursor.images.?[0];
        const buffer = cl.image_get_buffer(image) orelse return error.CursorCreationFailed;

        // Superficie dedicada ao cursor (reaproveitada).
        const surface = st.cursor_surface orelse blk: {
            const surface = self.lib.symbols.proxy_marshal_flags(
                self.state.compositor.?,
                api.wl_compositor_create_surface,
                &protocol.surface_interface,
                self.state.compositor_version,
                0,
                @as(?*anyopaque, null),
            ) orelse return error.CursorCreationFailed;
            st.cursor_surface = surface;
            break :blk surface;
        };
        // Anexa o buffer e confirma.
        _ = self.lib.symbols.proxy_marshal_flags(
            surface,
            api.wl_surface_attach,
            null,
            0,
            0,
            @as(?*anyopaque, @ptrCast(buffer)),
            @as(i32, 0),
            @as(i32, 0),
        );
        _ = self.lib.symbols.proxy_marshal_flags(
            surface,
            api.wl_surface_commit,
            null,
            0,
            0,
        );
        _ = self.lib.symbols.proxy_marshal_flags(
            pointer,
            api.wl_pointer_set_cursor,
            null,
            0,
            0,
            serial,
            @as(?*anyopaque, @ptrCast(surface)),
            @as(i32, @intCast(image.hotspot_x)),
            @as(i32, @intCast(image.hotspot_y)),
        );
        _ = self.lib.symbols.display_flush(self.display);
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
    /// Espera eventos na conexao do compositor (ou no wakeup) ate o
    /// timeout. O compositor pode acordar antes (evento) ou depois.
    pub fn waitEvents(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        timeout_ms: i32,
    ) u32 {
        if (timeout_ms == 0) {
            self.poll(reg, queue, state);
            return 0;
        }
        const fd = self.lib.symbols.display_get_fd(self.display);
        if (fd < 0) {
            self.poll(reg, queue, state);
            return 0;
        }
        var fds = [_]std.posix.pollfd{
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.wakeup_pipe.read_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, timeout_ms) catch 0;
        if (ready != 0 and (fds[1].revents & std.posix.POLL.IN) != 0) {
            self.wakeup_pipe.drain();
            return 0;
        }
        if (ready != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
            self.poll(reg, queue, state);
            return 1;
        }
        return 0;
    }

    /// Acorda uma thread bloqueada em `waitEvents`.
    pub fn wakeup(self: *Backend) void {
        self.wakeup_pipe.signal();
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        // Contexto do despacho: os callbacks do protocolo publicam
        // eventos na fila durante o poll.
        self.state.poll_reg = reg;
        self.state.poll_queue = queue;
        self.state.poll_input = state;
        defer {
            self.state.poll_reg = null;
            self.state.poll_queue = null;
            self.state.poll_input = null;
        }
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

    /// Slot da janela associada a uma superficie (o ponteiro e o
    /// teclado reportam a superficie, nao o id da janela).
    fn slotOfSurface(self: *const Backend, surface: ?*api.wl_proxy) ?u32 {
        const proxy = surface orelse return null;
        for (self.state.windows.items) |entry| {
            if (entry.surface == proxy) return entry.slot;
        }
        return null;
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

        // Mudanca de escala de uma janela.
        if (self.state.pending_scale_changed) {
            self.state.pending_scale_changed = false;
            for (self.state.windows.items) |entry| {
                if (entry.slot >= reg.slots.items.len) continue;
                if (!reg.slots.items[entry.slot].occupied) continue;
                // O slot reflete a escala corrente.
                reg.slots.items[entry.slot].scale = entry.scale;
                events.dispatch(queue, state, .{ .scale_changed = .{
                    .window = reg.idOf(entry.slot),
                    .scale = entry.scale,
                } });
            }
        }

        // Mudanca de display (modo/escala/posicao de um output).
        if (self.state.pending_display_change) {
            self.state.pending_display_change = false;
            events.dispatch(queue, state, .{ .display_change = .{} });
        }

        // Entrada do ponteiro (superficie -> janela).
        const pointer_slot = self.slotOfSurface(self.state.pointer_surface);
        var pointer_window: ?types.WindowId = null;
        if (pointer_slot) |slot| {
            if (slot < reg.slots.items.len and reg.slots.items[slot].occupied) {
                pointer_window = reg.idOf(slot);
            }
        }
        if (self.state.pending_move) {
            self.state.pending_move = false;
            events.dispatch(queue, state, .{ .pointer_move = .{
                .window = pointer_window,
                .x = self.state.pointer_x,
                .y = self.state.pointer_y,
            } });
        }
        if (self.state.pending_button) |button| {
            self.state.pending_button = null;
            events.dispatch(queue, state, .{ .pointer_button = .{
                .window = pointer_window,
                .button = button.button,
                .pressed = button.pressed,
                .x = self.state.pointer_x,
                .y = self.state.pointer_y,
                .modifiers = state.modifiers,
            } });
        }
        if (self.state.pending_scroll) |scroll| {
            self.state.pending_scroll = null;
            events.dispatch(queue, state, .{ .scroll = .{
                .window = pointer_window,
                .dx = scroll.dx,
                .dy = scroll.dy,
            } });
        }

        // Entrada do teclado (superficie com foco -> janela).
        const keyboard_slot = self.slotOfSurface(self.state.keyboard_surface);
        var keyboard_window: ?types.WindowId = null;
        if (keyboard_slot) |slot| {
            if (slot < reg.slots.items.len and reg.slots.items[slot].occupied) {
                keyboard_window = reg.idOf(slot);
            }
        }
        if (self.state.pending_focus) |focused| {
            self.state.pending_focus = null;
            if (keyboard_window) |wid| {
                if (keyboard_slot) |slot| {
                    reg.slots.items[slot].focused = focused;
                }
                events.dispatch(queue, state, .{ .focus = .{
                    .window = wid,
                    .focused = focused,
                } });
                // Perda de foco libera o que estava pressionado: o SO
                // nao entregara os key_up/button_up correspondentes.
                if (!focused) input.releaseAll(wid, queue, state);
            }
            if (!focused) self.state.keyboard_surface = null;
        }
        if (self.state.pending_key) |key| {
            self.state.pending_key = null;
            const modifiers: types.Modifiers = .{
                .shift = (self.state.keyboard_modifiers & xkb.mod_index_shift) != 0,
                .control = (self.state.keyboard_modifiers & xkb.mod_index_control) != 0,
                .alt = (self.state.keyboard_modifiers & xkb.mod_index_alt) != 0,
                .super = (self.state.keyboard_modifiers & xkb.mod_index_super) != 0,
            };
            const event: events.Event = if (key.pressed)
                .{ .key_down = .{
                    .window = keyboard_window,
                    .key = key.key,
                    .modifiers = modifiers,
                    .repeat = key.repeat,
                } }
            else
                .{ .key_up = .{
                    .window = keyboard_window,
                    .key = key.key,
                    .modifiers = modifiers,
                    .repeat = false,
                } };
            events.dispatch(queue, state, event);
        }
        if (self.state.pending_raw_key) |raw| {
            self.state.pending_raw_key = null;
            const modifiers: types.Modifiers = .{
                .shift = (self.state.keyboard_modifiers & xkb.mod_index_shift) != 0,
                .control = (self.state.keyboard_modifiers & xkb.mod_index_control) != 0,
                .alt = (self.state.keyboard_modifiers & xkb.mod_index_alt) != 0,
                .super = (self.state.keyboard_modifiers & xkb.mod_index_super) != 0,
            };
            // O evento `raw_key` exige uma janela (o teclado sem foco
            // nao tem tecla fisica para reportar).
            if (keyboard_window) |wid| {
                events.dispatch(queue, state, .{ .raw_key = .{
                    .window = wid,
                    .scancode = raw.scancode,
                    .pressed = raw.pressed,
                    .modifiers = modifiers,
                } });
            }
        }
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
    state.pending_display_change = true;
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
        state.pending_display_change = true;
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
    if (factor > 0 and factor != out.scale) {
        out.scale = factor;
        state.pending_display_change = true;
    }
}

fn onOutputName(data: ?*anyopaque, proxy: ?*api.wl_proxy, name: ?[*:0]const u8) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const out = state.outputByProxy(proxy orelse return) orelse return;
    if (name) |n| copyString(&out.name, n);
}

// --- Entrada de texto (zwp_text_input_v3) ---

/// Converte UTF-8 em codepoints e emite um `text_input` por codepoint.
fn emitText(
    state: *State,
    reg: *registry.Registry,
    queue: *events.EventQueue,
    input_state: *input.InputState,
    window_id: ?types.WindowId,
    text: []const u8,
) void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += 1;
            continue;
        };
        i += len;
        if (window_id) |wid| {
            events.dispatch(queue, input_state, .{ .text_input = .{
                .window = wid,
                .codepoint = @intCast(codepoint),
            } });
        }
    }
    _ = state;
    _ = reg;
}

/// Guarda o preedit (texto em composicao) e sinaliza o inicio/ fim da
/// composicao.
fn setComposition(
    state: *State,
    reg: *registry.Registry,
    queue: *events.EventQueue,
    input_state: *input.InputState,
    window_id: ?types.WindowId,
    text: []const u8,
) void {
    const allocator = state.allocator;
    if (state.composition_text.len > 0) allocator.free(state.composition_text);
    state.composition_text = allocator.dupe(u8, text) catch &.{};

    if (text.len == 0) {
        if (state.composition_active) {
            state.composition_active = false;
            if (window_id) |wid| {
                events.dispatch(queue, input_state, .{ .composition_end = .{ .window = wid } });
            }
        }
        return;
    }
    if (!state.composition_active) {
        state.composition_active = true;
        if (window_id) |wid| {
            events.dispatch(queue, input_state, .{ .composition_start = .{ .window = wid } });
        }
    }
    _ = reg;
}

fn onFractionalScalePreferred(
    data: ?*anyopaque,
    fractional_scale: ?*api.wl_proxy,
    scale: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const proxy = fractional_scale orelse return;
    // O valor e em 120avos (120 = 100%).
    const value = scaleToFraction(scale);
    for (state.windows.items) |*entry| {
        if (entry.fractional_scale == proxy) {
            entry.pending_scale = value;
            return;
        }
    }
}

fn onRelativeMotion(
    data: ?*anyopaque,
    relative_pointer: ?*api.wl_proxy,
    time: u32,
    dx: i32,
    dy: i32,
    dx_unaccel: i32,
    dy_unaccel: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    const proxy = relative_pointer orelse return;
    _ = time;
    _ = proxy;
    // O evento nao traz a superficie: usa a janela sob o ponteiro.
    const reg = state.poll_reg orelse return;
    const surface = state.pointer_surface orelse return;
    var window_id: ?types.WindowId = null;
    for (state.windows.items) |entry| {
        if (entry.surface != surface) continue;
        window_id = reg.idOf(entry.slot);
        break;
    }
    const wid = window_id orelse return;
    // `wl_fixed_t` = 24.8 fixo (1/256 de unidade).
    events.dispatch(state.poll_queue.?, state.poll_input.?, .{ .pointer_relative = .{
        .window = wid,
        .dx = @as(f64, @floatFromInt(dx)) / 256.0,
        .dy = @as(f64, @floatFromInt(dy)) / 256.0,
        .dx_unaccelerated = @as(f64, @floatFromInt(dx_unaccel)) / 256.0,
        .dy_unaccelerated = @as(f64, @floatFromInt(dy_unaccel)) / 256.0,
    } });
}

/// Aplica a mudanca de restricao confirmada pelo compositor.
fn applyConfirmedConstraint(
    state: *State,
    proxy: ?*api.wl_proxy,
    constraint: types.PointerConstraint,
) void {
    var window_id: ?types.WindowId = null;
    for (state.windows.items) |*entry| {
        const matches = (entry.locked_pointer == proxy) or (entry.confined_pointer == proxy);
        if (!matches) continue;
        entry.confirmed_constraint = constraint;
        const reg = state.poll_reg orelse return;
        window_id = reg.idOf(entry.slot);
        break;
    }
    const wid = window_id orelse return;
    if (state.poll_reg) |reg| {
        const slot = reg.slotOf(wid) orelse return;
        reg.slots.items[slot].pointer_constraint = constraint;
    }
    events.dispatch(state.poll_queue.?, state.poll_input.?, .{ .pointer_constraint = .{
        .window = wid,
        .constraint = constraint,
    } });
}

fn onPointerLocked(data: ?*anyopaque, locked_pointer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    applyConfirmedConstraint(state, locked_pointer, .lock);
}

fn onPointerUnlocked(data: ?*anyopaque, locked_pointer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    applyConfirmedConstraint(state, locked_pointer, .none);
}

fn onPointerConfined(data: ?*anyopaque, confined_pointer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    applyConfirmedConstraint(state, confined_pointer, .confine);
}

fn onPointerUnconfined(data: ?*anyopaque, confined_pointer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    applyConfirmedConstraint(state, confined_pointer, .none);
}

fn onTextInputEnter(
    data: ?*anyopaque,
    text_input: ?*api.wl_proxy,
    surface: ?*api.wl_proxy,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    state.text_input_surface = surface;
    // Habilita a entrada de texto para a superficie com foco.
    const proxy = text_input orelse return;
    _ = state.symbols.proxy_marshal_flags(
        proxy,
        api.zwp_text_input_v3_enable,
        null,
        0,
        0,
    );
    _ = state.symbols.proxy_marshal_flags(
        proxy,
        api.zwp_text_input_v3_commit,
        null,
        0,
        0,
    );
}

fn onTextInputLeave(
    data: ?*anyopaque,
    text_input: ?*api.wl_proxy,
    surface: ?*api.wl_proxy,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = surface;
    state.text_input_surface = null;
    const proxy = text_input orelse return;
    _ = state.symbols.proxy_marshal_flags(
        proxy,
        api.zwp_text_input_v3_disable,
        null,
        0,
        0,
    );
    _ = state.symbols.proxy_marshal_flags(
        proxy,
        api.zwp_text_input_v3_commit,
        null,
        0,
        0,
    );
}

fn onTextInputPreedit(
    data: ?*anyopaque,
    text_input: ?*api.wl_proxy,
    text: ?[*:0]const u8,
    cursor_pos: c_int,
    cursor_anchor: c_int,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = text_input;
    _ = cursor_pos;
    _ = cursor_anchor;
    const window_id = state.textInputWindowId();
    setComposition(
        state,
        state.poll_reg.?,
        state.poll_queue.?,
        state.poll_input.?,
        window_id,
        if (text) |t| std.mem.span(t) else "",
    );
}

fn onTextInputCommit(
    data: ?*anyopaque,
    text_input: ?*api.wl_proxy,
    text: ?[*:0]const u8,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = text_input;
    const window_id = state.textInputWindowId();
    const content: []const u8 = if (text) |t| std.mem.span(t) else "";
    emitText(state, state.poll_reg.?, state.poll_queue.?, state.poll_input.?, window_id, content);
    // O texto confirmado encerra a composicao.
    if (state.composition_active) {
        state.composition_active = false;
        if (state.composition_text.len > 0) {
            state.allocator.free(state.composition_text);
            state.composition_text = &.{};
        }
        if (window_id) |wid| {
            events.dispatch(state.poll_queue.?, state.poll_input.?, .{ .composition_end = .{ .window = wid } });
        }
    }
}

fn onTextInputDeleteSurrounding(
    data: ?*anyopaque,
    text_input: ?*api.wl_proxy,
    before: u32,
    after: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = text_input;
    // Quem apaga e a aplicacao: o evento traz quantos caracteres remover.
    const window_id = state.textInputWindowId();
    if (window_id) |wid| {
        events.dispatch(state.poll_queue.?, state.poll_input.?, .{ .surrounding_delete = .{
            .window = wid,
            .before = before,
            .after = after,
        } });
    }
}

fn onTextInputDone(data: ?*anyopaque, text_input: ?*api.wl_proxy, serial: u32) callconv(.c) void {
    _ = data;
    _ = text_input;
    _ = serial;
    // Fim do lote: os eventos anteriores ja foram publicados.
}

// --- Clipboard (wl_data_device) ---

fn onDeviceDataOffer(data: ?*anyopaque, device: ?*api.wl_proxy, offer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = device;
    const proxy = offer orelse return;
    state.selection_mimes.clearRetainingCapacity();
    state.symbols.proxy_add_listener(
        proxy,
        @ptrCast(&state.listeners.data_offer),
        @ptrCast(state),
    );
}

fn onDeviceEnter(
    data: ?*anyopaque,
    device: ?*api.wl_proxy,
    serial: u32,
    surface: ?*api.wl_proxy,
    x: i32,
    y: i32,
    icon: ?*api.wl_proxy,
) callconv(.c) void {
    // Drag & drop nao e suportado nesta etapa.
    _ = data;
    _ = device;
    _ = serial;
    _ = surface;
    _ = x;
    _ = y;
    _ = icon;
}

fn onDeviceLeave(data: ?*anyopaque, device: ?*api.wl_proxy) callconv(.c) void {
    _ = data;
    _ = device;
}

fn onDeviceMotion(data: ?*anyopaque, device: ?*api.wl_proxy, time: u32, x: i32, y: i32) callconv(.c) void {
    _ = data;
    _ = device;
    _ = time;
    _ = x;
    _ = y;
}

fn onDeviceDrop(data: ?*anyopaque, device: ?*api.wl_proxy) callconv(.c) void {
    _ = data;
    _ = device;
}

fn onDeviceSelection(data: ?*anyopaque, device: ?*api.wl_proxy, offer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = device;
    if (state.selection_offer) |old| {
        if (old != offer) state.symbols.proxy_destroy(old);
    }
    state.selection_offer = offer;
}

fn onOfferMime(data: ?*anyopaque, offer: ?*api.wl_proxy, mime: ?[*:0]const u8) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = offer;
    const name = mime orelse return;
    var buf: [64]u8 = @splat(0);
    var i: usize = 0;
    while (i + 1 < buf.len and name[i] != 0) : (i += 1) buf[i] = name[i];
    state.selection_mimes.append(state.allocator, buf) catch return;
}

fn onOfferSourceActions(data: ?*anyopaque, offer: ?*api.wl_proxy, actions: u32) callconv(.c) void {
    _ = data;
    _ = offer;
    _ = actions;
}

fn onOfferAction(data: ?*anyopaque, offer: ?*api.wl_proxy, action: u32) callconv(.c) void {
    _ = data;
    _ = offer;
    _ = action;
}

fn onSourceTarget(data: ?*anyopaque, source: ?*api.wl_proxy, mime: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = source;
    _ = mime;
}

fn onSourceSend(
    data: ?*anyopaque,
    source: ?*api.wl_proxy,
    mime: ?[*:0]const u8,
    fd: c_int,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = source;
    _ = mime;
    // O compositor pediu os dados: escrevemos o texto no fd enviado.
    const text = state.clipboard_text orelse "";
    writeAll(fd, text);
    _ = api.close(fd);
}

fn onSourceCancelled(data: ?*anyopaque, source: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = source;
    // Perdemos a selecao: o texto guardado nao e mais nosso.
    if (state.clipboard_text) |old| {
        state.allocator.free(old);
        state.clipboard_text = null;
    }
    state.clipboard_source = null;
}

fn onSourceDndDropPerformed(data: ?*anyopaque, source: ?*api.wl_proxy) callconv(.c) void {
    _ = data;
    _ = source;
}

fn onSourceDndFinished(data: ?*anyopaque, source: ?*api.wl_proxy) callconv(.c) void {
    _ = data;
    _ = source;
}

fn onSourceAction(data: ?*anyopaque, source: ?*api.wl_proxy, action: u32) callconv(.c) void {
    _ = data;
    _ = source;
    _ = action;
}

/// Converte a escala do protocolo (120avos) em fracao.
fn scaleToFraction(value: u32) types.Scale {
    if (value == 0) return .identity;
    // Reduz a fracao (ex.: 180/120 -> 3/2).
    var num = value;
    var den: u32 = 120;
    while (num % 2 == 0 and den % 2 == 0) {
        num /= 2;
        den /= 2;
    }
    return .{ .numerator = num, .denominator = den };
}

/// Escreve todo o conteudo no fd (escritas parciais sao repetidas).
fn writeAll(fd: c_int, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = api.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
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
    // O compositor pode anunciar capacidades depois do bind do seat:
    // o ponteiro e criado aqui (o teclado exige o keymap XKB e vem
    // na proxima etapa).
    if ((capabilities & api.wl_seat_capability_pointer) != 0 and state.pointer == null) {
        state.bindPointer();
        // O movimento relativo e ligado ao wl_pointer do seat.
        state.ensureRelativePointer();
    }
    if ((capabilities & api.wl_seat_capability_keyboard) != 0 and state.keyboard == null) {
        state.bindKeyboard();
    }
}

fn onSeatName(data: ?*anyopaque, seat: ?*api.wl_proxy, name: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

fn onKeyboardKeymap(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = keyboard;
    // Formato 1 = texto XKB ("xkb"); formato 0 = binario legado, que
    // nao e suportado.
    if (format != api.wl_keyboard_keymap_format_xkb_v1) return;
    if (fd < 0 or size == 0) return;

    // O compositor envia uma copia do descritor: e nossa a partir
    // daqui.
    defer _ = linux.close(@intCast(fd));

    const keymap = if (state.keymap) |*k| k else return;
    const bytes = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        @intCast(fd),
        0,
    ) catch return;
    defer std.posix.munmap(bytes);
    keymap.load(bytes) catch {
        // Keymap invalido: o teclado fica sem teclas (o resto do
        // backend continua funcionando).
    };
}

fn onKeyboardEnter(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    serial: u32,
    surface: ?*anyopaque,
    keys: ?*anyopaque,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = keyboard;
    _ = serial;
    _ = keys;
    state.keyboard_surface = @ptrCast(surface);
    state.pending_focus = true;
}

fn onKeyboardLeave(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    serial: u32,
    surface: ?*anyopaque,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = keyboard;
    _ = serial;
    _ = surface;
    // A superficie e mantida ate o evento de foco ser publicado (o
    // `focus` perdido pertence a janela que tinha o foco).
    state.pending_focus = false;
}

fn onKeyboardKey(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    serial: u32,
    time: u32,
    keycode: u32,
    key_state: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = keyboard;
    _ = serial;
    _ = time;
    const keymap = if (state.keymap) |*k| k else return;
    if (!keymap.ready) return;
    const pressed = key_state != 0;
    const sym = keymap.symForKey(keycode, pressed);
    if (sym == 0) return;
    const key = keysym.fromKeysym(sym);
    if (key == .unknown) return;
    state.pending_key = .{ .key = key, .pressed = pressed };
    // Tecla fisica: o keycode XKB (evdev + 8), como o keycode do X11.
    state.pending_raw_key = .{ .scancode = keycode, .pressed = pressed };
}

fn onKeyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    serial: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = keyboard;
    _ = serial;
    state.keyboard_modifiers = depressed;
    if (state.keymap) |*keymap| {
        keymap.updateModifiers(depressed, latched, locked, group);
    }
}

fn onKeyboardRepeatInfo(
    data: ?*anyopaque,
    keyboard: ?*api.wl_proxy,
    rate: i32,
    delay: i32,
) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = rate;
    _ = delay;
}

fn onPointerEnter(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    serial: u32,
    surface: ?*anyopaque,
    x: i32,
    y: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    state.last_pointer_serial = serial;
    state.pointer_surface = @ptrCast(surface);
    state.pointer_x = fixedToPixels(x);
    state.pointer_y = fixedToPixels(y);
    state.pending_move = true;
}

fn onPointerLeave(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    serial: u32,
    surface: ?*anyopaque,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = serial;
    _ = surface;
    state.pointer_surface = null;
}

fn onPointerMotion(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = time;
    state.pointer_x = fixedToPixels(x);
    state.pointer_y = fixedToPixels(y);
    state.pending_move = true;
}

fn onPointerButton(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    serial: u32,
    time: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    const state_ptr = stateFrom(data) orelse return;
    _ = pointer;
    _ = serial;
    _ = time;
    const mapped = buttonFromLinux(button) orelse return;
    state_ptr.pending_button = .{
        .button = mapped,
        .pressed = state != 0,
    };
}

fn onPointerAxis(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = time;
    const amount: f32 = @as(f32, @floatFromInt(value)) / 256.0;
    if (axis == api.wl_pointer_axis_vertical_scroll) {
        state.axis_vertical += amount;
    } else {
        state.axis_horizontal += amount;
    }
}

fn onPointerFrame(data: ?*anyopaque, pointer: ?*api.wl_proxy) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    // O `frame` fecha o lote de eventos do ponteiro: e a hora de
    // publicar a rolagem acumulada.
    const vertical = axisScroll(state.axis_vertical, state.axis_vertical_120, state.axis_vertical_discrete);
    const horizontal = axisScroll(state.axis_horizontal, state.axis_horizontal_120, state.axis_horizontal_discrete);
    state.axis_vertical = 0;
    state.axis_horizontal = 0;
    state.axis_vertical_120 = null;
    state.axis_horizontal_120 = null;
    state.axis_vertical_discrete = null;
    state.axis_horizontal_discrete = null;
    if (vertical == 0 and horizontal == 0) return;
    state.pending_scroll = .{ .dx = horizontal, .dy = vertical };
}

fn onPointerAxisSource(data: ?*anyopaque, pointer: ?*api.wl_proxy, source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = source;
}

fn onPointerAxisStop(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    axis: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
}

fn onPointerAxisDiscrete(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = time;
    if (axis == api.wl_pointer_axis_vertical_scroll) {
        state.axis_vertical_discrete = value;
    } else {
        state.axis_horizontal_discrete = value;
    }
}

fn onPointerAxisValue120(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = time;
    if (axis == api.wl_pointer_axis_vertical_scroll) {
        state.axis_vertical_120 = value;
    } else {
        state.axis_horizontal_120 = value;
    }
}

fn onPointerAxisRelativeDirection(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    axis: u32,
    direction: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
    _ = direction;
}

fn onPointerWarp(
    data: ?*anyopaque,
    pointer: ?*api.wl_proxy,
    time: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    const state = stateFrom(data) orelse return;
    _ = pointer;
    _ = time;
    state.pointer_x = fixedToPixels(x);
    state.pointer_y = fixedToPixels(y);
    state.pending_move = true;
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

/// Converte um valor `wl_fixed_t` (ponto fixo 24.8) em pixels.
fn fixedToPixels(value: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) / 256.0));
}

/// Codigos de botao do Linux (input-event-codes.h), usados pelo
/// `wl_pointer.button`.
const linux_btn_left: u32 = 0x110;
const linux_btn_right: u32 = 0x111;
const linux_btn_middle: u32 = 0x112;
const linux_btn_side: u32 = 0x113;
const linux_btn_extra: u32 = 0x114;

/// Mapeia o codigo de botao do Linux para o botao da API.
fn buttonFromLinux(code: u32) ?types.MouseButton {
    return switch (code) {
        linux_btn_left => .left,
        linux_btn_right => .right,
        linux_btn_middle => .middle,
        linux_btn_side => .back,
        linux_btn_extra => .forward,
        else => null,
    };
}

/// Converte o valor do eixo em "passos" de rolagem.
///
/// Prefere o valor em 120avos de grau (v8+), depois o numero de passos
/// discretos (v5+) e, por fim, o valor bruto (aproximacao: 120 pixels
/// por passo).
fn axisScroll(raw: f32, value120: ?i32, discrete: ?i32) f32 {
    if (value120) |v| return @as(f32, @floatFromInt(v)) / 120.0;
    if (discrete) |v| return @floatFromInt(v);
    if (raw == 0) return 0;
    return raw / 120.0;
}

/// Copia uma string C para um buffer fixo (sem terminador).
fn copyString(dest: []u8, src: [*:0]const u8) void {
    @memset(dest, 0);
    var i: usize = 0;
    while (i + 1 < dest.len and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
}

test "text input composition emits start, update and end" {
    var reg = registry.Registry{};
    defer reg.deinit(std.testing.allocator);
    var queue = try events.EventQueue.init(std.testing.allocator, 32);
    defer queue.deinit();
    var input_state = input.InputState{};

    const reserved = try reg.allocSlot(std.testing.allocator);
    const wid = reserved.id;

    var state = State{ .allocator = std.testing.allocator };
    state.poll_reg = &reg;
    state.poll_queue = &queue;
    state.poll_input = &input_state;

    // Preedit com texto: inicia a composicao.
    setComposition(&state, &reg, &queue, &input_state, wid, "abc");
    var ev = queue.next() orelse return error.TestExpectedCompositionEvent;
    try std.testing.expect(ev == .composition_start);
    try std.testing.expect(ev.composition_start.window.eql(wid));
    try std.testing.expect(state.composition_active);
    try std.testing.expectEqualStrings("abc", state.composition_text);

    // Preedit vazio: encerra a composicao.
    setComposition(&state, &reg, &queue, &input_state, wid, "");
    ev = queue.next() orelse return error.TestExpectedCompositionEvent;
    try std.testing.expect(ev == .composition_end);
    try std.testing.expect(!state.composition_active);
    try std.testing.expectEqual(@as(usize, 0), state.composition_text.len);
    try std.testing.expect(queue.next() == null);
}

test "text input commit emits one event per unicode codepoint" {
    var reg = registry.Registry{};
    defer reg.deinit(std.testing.allocator);
    var queue = try events.EventQueue.init(std.testing.allocator, 32);
    defer queue.deinit();
    var input_state = input.InputState{};

    const reserved = try reg.allocSlot(std.testing.allocator);
    const wid = reserved.id;

    var state = State{ .allocator = std.testing.allocator };
    state.poll_reg = &reg;
    state.poll_queue = &queue;
    state.poll_input = &input_state;

    // "olá" = 3 codepoints (o, l, á com acento).
    emitText(&state, &reg, &queue, &input_state, wid, "ol\xc3\xa1");
    const expected = [_]u32{ 'o', 'l', 0x00E1 };
    for (expected) |cp| {
        const ev = queue.next() orelse return error.TestExpectedTextInputEvent;
        try std.testing.expect(ev == .text_input);
        try std.testing.expect(ev.text_input.window.eql(wid));
        try std.testing.expectEqual(cp, ev.text_input.codepoint);
    }
    try std.testing.expect(queue.next() == null);

    // Caractere fora do BMP (emoji) em UTF-8: 1 codepoint.
    emitText(&state, &reg, &queue, &input_state, wid, "\xf0\x9f\x98\x80");
    const ev = queue.next() orelse return error.TestExpectedTextInputEvent;
    try std.testing.expect(ev == .text_input);
    try std.testing.expectEqual(@as(u32, 0x1F600), ev.text_input.codepoint);
}

test "fixed point converts to pixels" {
    try std.testing.expectEqual(@as(i32, 0), fixedToPixels(0));
    try std.testing.expectEqual(@as(i32, 1), fixedToPixels(256));
    try std.testing.expectEqual(@as(i32, 1), fixedToPixels(300));
    try std.testing.expectEqual(@as(i32, -1), fixedToPixels(-256));
}

test "linux button codes map to the public buttons" {
    try std.testing.expectEqual(types.MouseButton.left, buttonFromLinux(0x110).?);
    try std.testing.expectEqual(types.MouseButton.right, buttonFromLinux(0x111).?);
    try std.testing.expectEqual(types.MouseButton.middle, buttonFromLinux(0x112).?);
    try std.testing.expectEqual(types.MouseButton.back, buttonFromLinux(0x113).?);
    try std.testing.expectEqual(types.MouseButton.forward, buttonFromLinux(0x114).?);
    // Botoes desconhecidos nao viram evento.
    try std.testing.expect(buttonFromLinux(0x115) == null);
    try std.testing.expect(buttonFromLinux(0) == null);
}

test "axis scroll prefers the 120ths value" {
    try std.testing.expectEqual(@as(f32, 1.0), axisScroll(0, 120, null));
    try std.testing.expectEqual(@as(f32, -1.0), axisScroll(0, -120, null));
    // Sem 120ths, usa os passos discretos.
    try std.testing.expectEqual(@as(f32, 2.0), axisScroll(0, null, 2));
    // Sem nenhum deles, aproxima pelo valor bruto.
    try std.testing.expectEqual(@as(f32, 1.0), axisScroll(120, null, null));
    try std.testing.expectEqual(@as(f32, 0.0), axisScroll(0, null, null));
}

test "pointer callbacks record pending events" {
    var state = State{ .allocator = std.testing.allocator };
    defer state.windows.deinit(std.testing.allocator);

    onPointerMotion(@ptrCast(&state), null, 0, 256 * 10, 256 * 20);
    try std.testing.expect(state.pending_move);
    try std.testing.expectEqual(@as(i32, 10), state.pointer_x);
    try std.testing.expectEqual(@as(i32, 20), state.pointer_y);

    onPointerButton(@ptrCast(&state), null, 0, 0, 0x110, 1);
    try std.testing.expect(state.pending_button != null);
    try std.testing.expectEqual(types.MouseButton.left, state.pending_button.?.button);
    try std.testing.expect(state.pending_button.?.pressed);

    // A rolagem so e publicada no `frame` do compositor.
    onPointerAxis(@ptrCast(&state), null, 0, api.wl_pointer_axis_vertical_scroll, 256 * 120);
    try std.testing.expect(state.pending_scroll == null);
    onPointerFrame(@ptrCast(&state), null);
    try std.testing.expect(state.pending_scroll != null);
    try std.testing.expectEqual(@as(f32, 1.0), state.pending_scroll.?.dy);
    try std.testing.expectEqual(@as(f32, 0.0), state.pending_scroll.?.dx);
}
