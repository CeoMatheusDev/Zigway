// Carregamento dinamico opcional de libXrandr (monitores RandR 1.5+ e
// eventos 1.2+).
//
// Nao ha dependencia de link: a biblioteca e procurada em runtime. Sem
// libXrandr (ou sem RandR 1.5 no servidor), o backend X11 cai para a
// enumeracao de X screens; eventos ainda podem existir com RandR 1.2+.
// A ABI e declarada manualmente aqui, conforme a politica do projeto
// (sem @cImport/headers C).
//
// IMPORTANTE: libXrandr registra extensoes na Xlib. O display X deve ser
// fechado ANTES de `deinit` (dlclose); ver Backend.deinit.

const std = @import("std");
const api = @import("api.zig");
const types = @import("../../core/types.zig");

/// Layout de `XRRMonitorInfo` em Xrandr.h.
pub const MonitorInfo = extern struct {
    name: api.Atom,
    primary: api.XBool,
    automatic: api.XBool,
    noutput: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    mwidth: c_int,
    mheight: c_int,
    outputs: ?[*]c_ulong,
};

/// Layout de `XRRModeInfo` em Xrandr.h.
pub const ModeInfo = extern struct {
    id: c_ulong,
    width: c_uint,
    height: c_uint,
    dotClock: c_ulong,
    hSyncStart: c_uint,
    hSyncEnd: c_uint,
    hTotal: c_uint,
    hSkew: c_uint,
    vSyncStart: c_uint,
    vSyncEnd: c_uint,
    vTotal: c_uint,
    name: ?[*]u8,
    nameLength: c_uint,
    modeFlags: c_ulong,
};

/// Layout de `XRRScreenResources` em Xrandr.h.
pub const ScreenResources = extern struct {
    timestamp: c_ulong,
    configTimestamp: c_ulong,
    ncrtc: c_int,
    crtcs: ?[*]c_ulong,
    noutput: c_int,
    outputs: ?[*]c_ulong,
    nmode: c_int,
    modes: ?[*]ModeInfo,
};

/// Layout de `XRROutputInfo` em Xrandr.h.
///
/// ATENCAO: o layout NAO e estavel entre versoes da libXrandr. Em
/// xorgproto recentes `Connection` e `SubpixelOrder` sao `unsigned short`
/// (96 bytes); em versoes antigas sao enums (`int`, 104 bytes). Por isso a
/// estrutura e lida por offsets com deteccao de layout em runtime
/// (`OutputLayout`), em vez de confiar em um unico layout.
pub const OutputInfoShort = extern struct {
    timestamp: c_ulong,
    crtc: c_ulong,
    name: ?[*]u8,
    nameLen: c_int,
    mm_width: c_ulong,
    mm_height: c_ulong,
    connection: c_ushort,
    subpixel_order: c_ushort,
    ncrtc: c_int,
    crtcs: ?[*]c_ulong,
    nclone: c_int,
    clones: ?[*]c_ulong,
    nmode: c_int,
    npreferred: c_int,
    modes: ?[*]c_ulong,
};

/// Variante antiga de `XRROutputInfo` (enums de 4 bytes).
pub const OutputInfoEnum = extern struct {
    timestamp: c_ulong,
    crtc: c_ulong,
    name: ?[*]u8,
    nameLen: c_int,
    mm_width: c_ulong,
    mm_height: c_ulong,
    connection: c_int,
    subpixel_order: c_int,
    ncrtc: c_int,
    crtcs: ?[*]c_ulong,
    nclone: c_int,
    clones: ?[*]c_ulong,
    nmode: c_int,
    npreferred: c_int,
    modes: ?[*]c_ulong,
};

/// Layout de `XRROutputInfo` detectado em runtime.
pub const OutputLayout = enum {
    /// `Connection`/`SubpixelOrder` de 2 bytes (xorgproto recente).
    shorts,
    /// `Connection`/`SubpixelOrder` de 4 bytes (xorgproto antigo).
    enums,
};

/// Layout de `XRRCrtcInfo` em Xrandr.h.
pub const CrtcInfo = extern struct {
    timestamp: c_ulong,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
    mode: c_ulong,
    rotation: c_ushort,
    noutput: c_int,
    outputs: ?[*]c_ulong,
    rotations: c_ushort,
    npossible: c_int,
    possible: ?[*]c_ulong,
};

const QueryVersionFn = *const fn (*api.Display, *c_int, *c_int) callconv(.c) api.Status;
const QueryExtensionFn = *const fn (*api.Display, *c_int, *c_int) callconv(.c) api.XBool;
const SelectInputFn = *const fn (*api.Display, api.Window, c_int) callconv(.c) void;
const UpdateConfigurationFn = *const fn (*api.XEvent) callconv(.c) api.Status;
const GetMonitorsFn = *const fn (
    *api.Display,
    api.Window,
    api.XBool,
    *c_int,
) callconv(.c) ?[*]MonitorInfo;
const FreeMonitorsFn = *const fn ([*]MonitorInfo) callconv(.c) void;

// --- Modos de video (RandR 1.2+) ---
const GetScreenResourcesFn = *const fn (*api.Display, api.Window) callconv(.c) ?*ScreenResources;
const GetScreenResourcesCurrentFn = *const fn (*api.Display, api.Window) callconv(.c) ?*ScreenResources;
const FreeScreenResourcesFn = *const fn (*ScreenResources) callconv(.c) void;
const GetOutputInfoFn = *const fn (
    *api.Display,
    *ScreenResources,
    c_ulong,
) callconv(.c) ?*anyopaque;
const FreeOutputInfoFn = *const fn (*anyopaque) callconv(.c) void;
const GetCrtcInfoFn = *const fn (
    *api.Display,
    *ScreenResources,
    c_ulong,
) callconv(.c) ?*CrtcInfo;
const FreeCrtcInfoFn = *const fn (*CrtcInfo) callconv(.c) void;
const SetCrtcConfigFn = *const fn (
    *api.Display,
    *ScreenResources,
    c_ulong,
    c_ulong,
    c_int,
    c_int,
    c_ulong,
    c_ushort,
    ?[*]c_ulong,
    c_int,
) callconv(.c) api.Status;
const SetScreenSizeFn = *const fn (
    *api.Display,
    api.Window,
    c_int,
    c_int,
    c_int,
    c_int,
) callconv(.c) void;

/// Mascaras de evento RandR 1.2 (Xrandr.h).
const RRScreenChangeNotifyMask: c_int = 1 << 0;
const RRCrtcChangeNotifyMask: c_int = 1 << 1;
const RROutputChangeNotifyMask: c_int = 1 << 2;

/// Handle e simbolos de libXrandr. Mantido vivo enquanto o display X
/// estiver aberto.
pub const Lib = struct {
    dyn: std.DynLib,
    query_version: QueryVersionFn,
    /// Opcionais: sem eles nao ha notificacao de mudanca de display, mas a
    /// enumeracao de monitores continua funcionando.
    query_extension: ?QueryExtensionFn,
    select_input: ?SelectInputFn,
    update_configuration: ?UpdateConfigurationFn,
    /// Opcionais: sem ambos nao ha enumeracao RandR (fallback X screens).
    get_monitors: ?GetMonitorsFn,
    free_monitors: ?FreeMonitorsFn,
    /// Opcionais: modos de video (RandR 1.2+). Leitura exige os simbolos de
    /// consulta; a troca exige `set_crtc_config`.
    get_screen_resources: ?GetScreenResourcesFn,
    get_screen_resources_current: ?GetScreenResourcesCurrentFn,
    free_screen_resources: ?FreeScreenResourcesFn,
    get_output_info: ?GetOutputInfoFn,
    free_output_info: ?FreeOutputInfoFn,
    get_crtc_info: ?GetCrtcInfoFn,
    free_crtc_info: ?FreeCrtcInfoFn,
    set_crtc_config: ?SetCrtcConfigFn,
    set_screen_size: ?SetScreenSizeFn,

    /// Tenta carregar libXrandr. `XRRQueryVersion` e obrigatorio; os
    /// simbolos de monitores (1.5+) e eventos sao opcionais. Retorna null
    /// se a biblioteca ou `XRRQueryVersion` nao existir.
    pub fn load() ?Lib {
        var dyn = std.DynLib.open("libXrandr.so.2") catch blk: {
            break :blk std.DynLib.open("libXrandr.so") catch return null;
        };
        const query_version = dyn.lookup(QueryVersionFn, "XRRQueryVersion") orelse {
            dyn.close();
            return null;
        };
        const query_extension = dyn.lookup(QueryExtensionFn, "XRRQueryExtension");
        const select_input = dyn.lookup(SelectInputFn, "XRRSelectInput");
        const update_configuration = dyn.lookup(UpdateConfigurationFn, "XRRUpdateConfiguration");
        const get_monitors = dyn.lookup(GetMonitorsFn, "XRRGetMonitors");
        const free_monitors = dyn.lookup(FreeMonitorsFn, "XRRFreeMonitors");
        const get_screen_resources = dyn.lookup(GetScreenResourcesFn, "XRRGetScreenResources");
        const get_screen_resources_current = dyn.lookup(
            GetScreenResourcesCurrentFn,
            "XRRGetScreenResourcesCurrent",
        );
        const free_screen_resources = dyn.lookup(FreeScreenResourcesFn, "XRRFreeScreenResources");
        const get_output_info = dyn.lookup(GetOutputInfoFn, "XRRGetOutputInfo");
        const free_output_info = dyn.lookup(FreeOutputInfoFn, "XRRFreeOutputInfo");
        const get_crtc_info = dyn.lookup(GetCrtcInfoFn, "XRRGetCrtcInfo");
        const free_crtc_info = dyn.lookup(FreeCrtcInfoFn, "XRRFreeCrtcInfo");
        const set_crtc_config = dyn.lookup(SetCrtcConfigFn, "XRRSetCrtcConfig");
        const set_screen_size = dyn.lookup(SetScreenSizeFn, "XRRSetScreenSize");
        return .{
            .dyn = dyn,
            .query_version = query_version,
            .query_extension = query_extension,
            .select_input = select_input,
            .update_configuration = update_configuration,
            .get_monitors = get_monitors,
            .free_monitors = free_monitors,
            .get_screen_resources = get_screen_resources,
            .get_screen_resources_current = get_screen_resources_current,
            .free_screen_resources = free_screen_resources,
            .get_output_info = get_output_info,
            .free_output_info = free_output_info,
            .get_crtc_info = get_crtc_info,
            .free_crtc_info = free_crtc_info,
            .set_crtc_config = set_crtc_config,
            .set_screen_size = set_screen_size,
        };
    }

    pub fn deinit(self: *Lib) void {
        self.dyn.close();
    }

    /// RandR 1.5+ expoe `XRRGetMonitors`. Versoes antigas usam CRTCs, que
    /// nao sao tratadas aqui (fallback para X screens).
    pub fn supportsMonitors(self: *const Lib, display: *api.Display) bool {
        if (self.get_monitors == null or self.free_monitors == null) return false;
        var major: c_int = 0;
        var minor: c_int = 0;
        if (self.query_version(display, &major, &minor) == 0) return false;
        return major > 1 or (major == 1 and minor >= 5);
    }

    /// Registra screen/crtc/output notifications no root e devolve o
    /// event_base do RandR. Retorna null se a extensao ou os simbolos
    /// opcionais nao estiverem disponiveis (nesse caso nao ha evento de
    /// mudanca de display).
    pub fn enableEvents(self: *const Lib, display: *api.Display, root: api.Window) ?c_int {
        const query = self.query_extension orelse return null;
        const select = self.select_input orelse return null;
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        if (query(display, &event_base, &error_base) == 0) return null;
        select(
            display,
            root,
            RRScreenChangeNotifyMask | RRCrtcChangeNotifyMask | RROutputChangeNotifyMask,
        );
        return event_base;
    }

    /// Atualiza o cache de tela da Xlib apos um `RRScreenChangeNotify`.
    pub fn updateConfiguration(self: *const Lib, event: *api.XEvent) void {
        if (self.update_configuration) |update| _ = update(event);
    }

    /// Snapshot dos monitores ativos. Retorna null quando a consulta falha
    /// (o chamador deve usar o fallback de X screens); erros de alocacao
    /// sao propagados.
    pub fn monitors(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        allocator: std.mem.Allocator,
    ) !?[]types.DisplayInfo {
        const get_monitors = self.get_monitors orelse return null;
        const free_monitors = self.free_monitors orelse return null;
        var count: c_int = 0;
        const ptr = get_monitors(display, root, api.True, &count) orelse return null;
        defer free_monitors(ptr);
        if (count <= 0) return null;

        const n: usize = @intCast(count);
        // Valida antes de alocar: geometria invalida cai para X screens.
        for (ptr[0..n]) |monitor| {
            const width = std.math.cast(u32, monitor.width) orelse return null;
            const height = std.math.cast(u32, monitor.height) orelse return null;
            if (width == 0 or height == 0) return null;
        }

        const displays = try allocator.alloc(types.DisplayInfo, n);
        errdefer allocator.free(displays);
        for (ptr[0..n], 0..) |monitor, i| {
            displays[i] = .{
                // Indice do snapshot; `id` e opaco e pode mudar em hotplug.
                .id = .{ .raw = @intCast(i) },
                .x = @intCast(monitor.x),
                .y = @intCast(monitor.y),
                .width = @intCast(monitor.width),
                .height = @intCast(monitor.height),
                .primary = monitor.primary != 0,
            };
        }
        return displays;
    }

    // --- Modos de video (RandR 1.2+) ---

    /// true quando os simbolos de leitura de recursos/modos existem.
    pub fn supportsModes(self: *const Lib) bool {
        return self.get_screen_resources != null or self.get_screen_resources_current != null;
    }

    /// Recursos de tela do RandR. Prefere a variante "current" (1.3+),
    /// que nao sincroniza com o servidor.
    fn screenResources(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
    ) ?*ScreenResources {
        if (self.get_screen_resources_current) |get| {
            if (get(display, root)) |resources| return resources;
        }
        if (self.get_screen_resources) |get| return get(display, root);
        return null;
    }

    fn freeScreenResources(self: *const Lib, resources: *ScreenResources) void {
        if (self.free_screen_resources) |free| free(resources);
    }

    /// Procura um modo pelo id X11 dentro dos recursos de tela.
    fn findMode(resources: *const ScreenResources, id: c_ulong) ?*const ModeInfo {
        if (resources.nmode <= 0) return null;
        const modes = resources.modes orelse return null;
        const n: usize = @intCast(resources.nmode);
        for (modes[0..n]) |*mode| {
            if (mode.id == id) return mode;
        }
        return null;
    }

    // --- Leitura crua de `XRROutputInfo` (layout varia entre versoes) ---

    fn readU16(raw: [*]const u8, offset: usize) u16 {
        return std.mem.readInt(u16, @as(*const [2]u8, @ptrCast(raw + offset)), .little);
    }

    fn readU32(raw: [*]const u8, offset: usize) u32 {
        return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(raw + offset)), .little);
    }

    fn readU64(raw: [*]const u8, offset: usize) u64 {
        return std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(raw + offset)), .little);
    }

    /// CRTC do output (offset estavel entre os dois layouts).
    fn outCrtc(raw: [*]const u8) c_ulong {
        return @intCast(readU64(raw, 8));
    }

    /// `RR_Connected` == 0. O offset e estavel; o tipo muda entre versoes,
    /// mas o valor de 16 bits e o mesmo.
    fn outConnected(raw: [*]const u8) bool {
        return readU16(raw, 48) == 0;
    }

    fn outModeCount(raw: [*]const u8, layout: OutputLayout) c_int {
        const value = switch (layout) {
            .shorts => readU32(raw, 80),
            .enums => readU32(raw, 88),
        };
        return std.math.cast(c_int, value) orelse -1;
    }

    fn outPreferredCount(raw: [*]const u8, layout: OutputLayout) c_int {
        const value = switch (layout) {
            .shorts => readU32(raw, 84),
            .enums => readU32(raw, 92),
        };
        return std.math.cast(c_int, value) orelse -1;
    }

    fn outModeIds(raw: [*]const u8, layout: OutputLayout) ?[*]c_ulong {
        const value = switch (layout) {
            .shorts => readU64(raw, 88),
            .enums => readU64(raw, 96),
        };
        if (value == 0) return null;
        return @ptrFromInt(value);
    }

    /// Detecta o layout de `XRROutputInfo` da libXrandr em uso. O layout
    /// muda entre versoes do Xrandr (`Connection`/`SubpixelOrder` de 2 ou
    /// 4 bytes), entao a struct e lida por offsets validados.
    fn detectOutputLayout(
        self: *const Lib,
        display: *api.Display,
        resources: *ScreenResources,
        output_id: c_ulong,
    ) OutputLayout {
        const get_output = self.get_output_info orelse return .shorts;
        const free_output = self.free_output_info orelse return .shorts;
        const ptr = get_output(display, resources, output_id) orelse return .shorts;
        defer free_output(ptr);
        const raw: [*]const u8 = @ptrCast(ptr);
        // Offset 80 e 88 existem nos dois layouts (96 bytes no minimo).
        const a_ok = readU32(raw, 80) <= 4096;
        const b_ok = readU32(raw, 88) <= 4096;
        if (a_ok and !b_ok) return .shorts;
        if (b_ok and !a_ok) return .enums;
        if (layoutValid(raw, .shorts, resources)) return .shorts;
        if (layoutValid(raw, .enums, resources)) return .enums;
        return .shorts;
    }

    /// Confere a interpretacao do layout contra os modos conhecidos do
    /// servidor: os ids informados precisam existir em `resources.modes`.
    fn layoutValid(
        raw: [*]const u8,
        layout: OutputLayout,
        resources: *const ScreenResources,
    ) bool {
        const count = outModeCount(raw, layout);
        if (count < 0) return false;
        const preferred = outPreferredCount(raw, layout);
        if (preferred < 0 or preferred > count) return false;
        if (count == 0) return true;
        const ids = outModeIds(raw, layout) orelse return false;
        const n: usize = @intCast(count);
        const check = @min(n, 8);
        for (ids[0..check]) |id| {
            if (findMode(resources, id) == null) return false;
        }
        return true;
    }

    /// true quando o output oferece o modo informado.
    fn modeOffered(raw: [*]const u8, layout: OutputLayout, id: c_ulong) bool {
        const count = outModeCount(raw, layout);
        if (count <= 0) return false;
        const ids = outModeIds(raw, layout) orelse return false;
        const n: usize = @intCast(count);
        for (ids[0..n]) |mode_id| {
            if (mode_id == id) return true;
        }
        return false;
    }

    /// Taxa vertical aproximada em milihertz a partir de `dotClock` e dos
    /// totais de linha/coluna. 0 quando os dados sao invalidos.
    fn refreshMilliHz(mode: *const ModeInfo) u32 {
        if (mode.dotClock == 0) return 0;
        if (mode.hTotal == 0 or mode.vTotal == 0) return 0;
        const total = @as(u64, mode.hTotal) * @as(u64, mode.vTotal);
        const value = (@as(u64, mode.dotClock) * 1000) / total;
        return std.math.cast(u32, value) orelse 0;
    }

    /// Modos de video oferecidos por um monitor (indice do snapshot de
    /// `monitors`). Retorna null quando RandR/monitores nao estao
    /// disponiveis; `error.InvalidDisplay` quando o indice nao existe.
    pub fn monitorModes(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        monitor_index: u32,
        allocator: std.mem.Allocator,
    ) !?[]types.DisplayMode {
        const get_monitors = self.get_monitors orelse return null;
        const free_monitors = self.free_monitors orelse return null;
        const get_output = self.get_output_info orelse return null;
        const free_output = self.free_output_info orelse return null;
        const get_crtc = self.get_crtc_info orelse return null;
        const free_crtc = self.free_crtc_info orelse return null;
        if (!self.supportsModes()) return null;

        var count: c_int = 0;
        const monitor_list = get_monitors(display, root, api.True, &count) orelse return null;
        defer free_monitors(monitor_list);
        if (count <= 0) return null;
        if (monitor_index >= @as(u32, @intCast(count))) return error.InvalidDisplay;

        const resources = self.screenResources(display, root) orelse
            return error.DisplayModeFailed;
        defer self.freeScreenResources(resources);

        var list: std.ArrayList(types.DisplayMode) = .empty;
        defer list.deinit(allocator);

        const monitor = monitor_list[monitor_index];
        if (monitor.noutput > 0) {
            if (monitor.outputs) |outputs| {
                const nout: usize = @intCast(monitor.noutput);
                const layout = self.detectOutputLayout(display, resources, outputs[0]);
                for (outputs[0..nout]) |output_id| {
                    const output = get_output(display, resources, output_id) orelse continue;
                    defer free_output(output);
                    const raw: [*]const u8 = @ptrCast(output);
                    if (!outConnected(raw)) continue;

                    const crtc_id = outCrtc(raw);
                    var current_mode: c_ulong = 0;
                    if (crtc_id != 0) {
                        const crtc = get_crtc(display, resources, crtc_id) orelse continue;
                        defer free_crtc(crtc);
                        current_mode = crtc.mode;
                    }

                    const mode_count = outModeCount(raw, layout);
                    if (mode_count <= 0) continue;
                    const mode_ids = outModeIds(raw, layout) orelse continue;
                    const preferred_count = outPreferredCount(raw, layout);
                    const n: usize = @intCast(mode_count);
                    for (mode_ids[0..n], 0..) |mode_id, mode_index| {
                        if (mode_id == 0) continue;
                        const info = findMode(resources, mode_id) orelse continue;
                        const width = std.math.cast(u32, info.width) orelse continue;
                        const height = std.math.cast(u32, info.height) orelse continue;
                        if (width == 0 or height == 0) continue;
                        const is_current = mode_id == current_mode;
                        const is_preferred = @as(c_int, @intCast(mode_index)) < preferred_count;

                        var seen = false;
                        for (list.items) |*existing| {
                            if (existing.id.raw == @as(u64, mode_id)) {
                                existing.current = existing.current or is_current;
                                existing.preferred = existing.preferred or is_preferred;
                                seen = true;
                                break;
                            }
                        }
                        if (seen) continue;

                        try list.append(allocator, .{
                            .id = .{ .raw = @as(u64, mode_id) },
                            .width = width,
                            .height = height,
                            .refresh_mhz = refreshMilliHz(info),
                            .current = is_current,
                            .preferred = is_preferred,
                        });
                    }
                }
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    /// Aplica um modo de video no monitor (indice do snapshot de
    /// `monitors`). Preserva posicao, rotacao e conjunto de outputs do
    /// CRTC; a tela e reajustada para envelopar os CRTCs ativos.
    pub fn setMonitorMode(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        monitor_index: u32,
        mode_id: u64,
    ) !void {
        const get_monitors = self.get_monitors orelse return error.DisplayModeUnsupported;
        const free_monitors = self.free_monitors orelse return error.DisplayModeUnsupported;
        const get_output = self.get_output_info orelse return error.DisplayModeUnsupported;
        const free_output = self.free_output_info orelse return error.DisplayModeUnsupported;
        const get_crtc = self.get_crtc_info orelse return error.DisplayModeUnsupported;
        const free_crtc = self.free_crtc_info orelse return error.DisplayModeUnsupported;
        const set_crtc = self.set_crtc_config orelse return error.DisplayModeUnsupported;

        const native_mode = std.math.cast(c_ulong, mode_id) orelse
            return error.InvalidDisplayMode;

        var count: c_int = 0;
        const monitor_list = get_monitors(display, root, api.True, &count) orelse
            return error.DisplayModeFailed;
        defer free_monitors(monitor_list);
        if (count <= 0) return error.InvalidDisplay;
        if (monitor_index >= @as(u32, @intCast(count))) return error.InvalidDisplay;

        const resources = self.screenResources(display, root) orelse
            return error.DisplayModeFailed;
        defer self.freeScreenResources(resources);

        const target = findMode(resources, native_mode) orelse
            return error.InvalidDisplayMode;

        const monitor = monitor_list[monitor_index];
        if (monitor.noutput <= 0) return error.InvalidDisplayMode;
        const outputs = monitor.outputs orelse return error.InvalidDisplayMode;
        const nout: usize = @intCast(monitor.noutput);
        const layout = self.detectOutputLayout(display, resources, outputs[0]);

        for (outputs[0..nout]) |output_id| {
            const output = get_output(display, resources, output_id) orelse continue;
            defer free_output(output);
            const raw: [*]const u8 = @ptrCast(output);
            if (!outConnected(raw)) continue;
            const crtc_id = outCrtc(raw);
            if (crtc_id == 0) continue;
            if (!modeOffered(raw, layout, native_mode)) continue;

            const crtc = get_crtc(display, resources, crtc_id) orelse continue;
            defer free_crtc(crtc);
            if (crtc.noutput <= 0) continue;
            const crtc_outputs = crtc.outputs orelse continue;

            // Modo maior que a tela atual: expande a tela antes de aplicar.
            self.ensureScreenSize(
                display,
                root,
                resources,
                crtc_id,
                target.width,
                target.height,
            );

            // `XRRSetCrtcConfig` devolve o status do protocolo RandR:
            // 0 = sucesso (RRSetConfigSuccess), 1 = config time invalido,
            // 2 = time invalido.
            const status = set_crtc(
                display,
                resources,
                crtc_id,
                api.CurrentTime,
                crtc.x,
                crtc.y,
                native_mode,
                crtc.rotation,
                crtc_outputs,
                crtc.noutput,
            );
            if (status != 0) return error.DisplayModeFailed;

            // Readback: o modo precisa estar de fato aplicado.
            const verify = get_crtc(display, resources, crtc_id) orelse
                return error.DisplayModeFailed;
            defer free_crtc(verify);
            if (verify.mode != native_mode) return error.DisplayModeFailed;

            // Reajusta a tela ao novo conjunto de CRTCs ativos.
            self.applyScreenSize(display, root, resources);
            _ = api.XFlush(display);
            return;
        }
        return error.InvalidDisplayMode;
    }

    /// Expande a tela quando o modo alvo ultrapassa a area atual.
    fn ensureScreenSize(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        resources: *ScreenResources,
        crtc_id: c_ulong,
        width: c_uint,
        height: c_uint,
    ) void {
        const bounds = self.activeBounds(display, resources, crtc_id, width, height) orelse return;
        const current = screenSize(display, root);
        if (bounds.width <= current.width and bounds.height <= current.height) return;
        self.setScreenSize(
            display,
            root,
            @max(bounds.width, current.width),
            @max(bounds.height, current.height),
        );
    }

    /// Reajusta a tela para envelopar todos os CRTCs ativos.
    fn applyScreenSize(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        resources: *ScreenResources,
    ) void {
        const bounds = self.activeBounds(display, resources, null, 0, 0) orelse return;
        if (bounds.width <= 0 or bounds.height <= 0) return;
        const current = screenSize(display, root);
        if (bounds.width == current.width and bounds.height == current.height) return;
        self.setScreenSize(display, root, bounds.width, bounds.height);
    }

    const Bounds = struct { width: i32, height: i32 };

    /// Tamanho real da tela no servidor. `XDisplayWidth`/`XDisplayHeight`
    /// consultam o cache da Xlib, que so e atualizado quando o evento
    /// RandR e processado (e pode estar obsoleto logo apos uma troca).
    fn screenSize(display: *api.Display, root: api.Window) Bounds {
        // A libX11 desreferencia os ponteiros de saida: todos sao obrigatorios.
        var root_out: api.Window = 0;
        var x_out: c_int = 0;
        var y_out: c_int = 0;
        var width: c_uint = 0;
        var height: c_uint = 0;
        var border: c_uint = 0;
        var depth: c_uint = 0;
        const ok = api.XGetGeometry(
            display,
            root,
            &root_out,
            &x_out,
            &y_out,
            &width,
            &height,
            &border,
            &depth,
        );
        if (ok != 0) {
            return .{
                .width = std.math.cast(i32, width) orelse 0,
                .height = std.math.cast(i32, height) orelse 0,
            };
        }
        const screen = api.XDefaultScreen(display);
        return .{
            .width = api.XDisplayWidth(display, screen),
            .height = api.XDisplayHeight(display, screen),
        };
    }

    /// Envelope (largura/altura) dos CRTCs ativos. Quando `override_crtc`
    /// e informado, usa `width`/`height` no lugar da geometria atual
    /// daquele CRTC (usado para prever o tamanho antes de aplicar).
    fn activeBounds(
        self: *const Lib,
        display: *api.Display,
        resources: *ScreenResources,
        override_crtc: ?c_ulong,
        width: c_uint,
        height: c_uint,
    ) ?Bounds {
        const get_crtc = self.get_crtc_info orelse return null;
        const free_crtc = self.free_crtc_info orelse return null;
        if (resources.ncrtc <= 0) return null;
        const crtcs = resources.crtcs orelse return null;
        const n: usize = @intCast(resources.ncrtc);
        var max_w: i32 = 0;
        var max_h: i32 = 0;
        for (crtcs[0..n]) |crtc_id| {
            const info = get_crtc(display, resources, crtc_id) orelse continue;
            defer free_crtc(info);
            if (info.mode == 0) continue;
            const w: i32 = if (override_crtc != null and override_crtc.? == crtc_id)
                @intCast(width)
            else
                @intCast(info.width);
            const h: i32 = if (override_crtc != null and override_crtc.? == crtc_id)
                @intCast(height)
            else
                @intCast(info.height);
            const right = info.x + w;
            const bottom = info.y + h;
            if (right > max_w) max_w = right;
            if (bottom > max_h) max_h = bottom;
        }
        if (max_w <= 0 or max_h <= 0) return null;
        return .{ .width = max_w, .height = max_h };
    }

    /// Aplica `XRRSetScreenSize` preservando a densidade (mm) atual.
    fn setScreenSize(
        self: *const Lib,
        display: *api.Display,
        root: api.Window,
        width: i32,
        height: i32,
    ) void {
        const set_size = self.set_screen_size orelse return;
        const current = screenSize(display, root);
        const old_w = current.width;
        const old_h = current.height;
        var mm_w: i32 = 0;
        var mm_h: i32 = 0;
        if (old_w > 0 and old_h > 0) {
            const screen = api.XDefaultScreen(display);
            const old_mm_w = api.XDisplayWidthMM(display, screen);
            const old_mm_h = api.XDisplayHeightMM(display, screen);
            const scaled_w = @divTrunc(@as(i64, old_mm_w) * @as(i64, width), @as(i64, old_w));
            const scaled_h = @divTrunc(@as(i64, old_mm_h) * @as(i64, height), @as(i64, old_h));
            mm_w = @intCast(@max(@as(i64, 1), scaled_w));
            mm_h = @intCast(@max(@as(i64, 1), scaled_h));
        }
        set_size(display, root, width, height, mm_w, mm_h);
    }
};

test "XRRMonitorInfo layout matches Xrandr.h (64-bit)" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(MonitorInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MonitorInfo, "name"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(MonitorInfo, "primary"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(MonitorInfo, "automatic"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(MonitorInfo, "noutput"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(MonitorInfo, "x"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(MonitorInfo, "y"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(MonitorInfo, "width"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(MonitorInfo, "height"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(MonitorInfo, "mwidth"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(MonitorInfo, "mheight"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(MonitorInfo, "outputs"));
}

test "XRRModeInfo layout matches Xrandr.h (64-bit)" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(ModeInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ModeInfo, "id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ModeInfo, "width"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(ModeInfo, "height"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ModeInfo, "dotClock"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ModeInfo, "hSyncStart"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ModeInfo, "vSyncStart"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ModeInfo, "vTotal"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ModeInfo, "name"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(ModeInfo, "nameLength"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(ModeInfo, "modeFlags"));
}

test "XRRScreenResources layout matches Xrandr.h (64-bit)" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(ScreenResources));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ScreenResources, "timestamp"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ScreenResources, "configTimestamp"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ScreenResources, "ncrtc"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ScreenResources, "crtcs"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(ScreenResources, "noutput"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ScreenResources, "outputs"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ScreenResources, "nmode"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ScreenResources, "modes"));
}

test "XRROutputInfo layout matches Xrandr.h (64-bit, duas variantes)" {
    if (@sizeOf(usize) != 8) return;
    // Variante com `Connection`/`SubpixelOrder` de 2 bytes (xorgproto
    // recente): 96 bytes.
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(OutputInfoShort));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(OutputInfoShort, "timestamp"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(OutputInfoShort, "crtc"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(OutputInfoShort, "name"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(OutputInfoShort, "nameLen"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(OutputInfoShort, "mm_width"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(OutputInfoShort, "mm_height"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(OutputInfoShort, "connection"));
    try std.testing.expectEqual(@as(usize, 50), @offsetOf(OutputInfoShort, "subpixel_order"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(OutputInfoShort, "ncrtc"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(OutputInfoShort, "crtcs"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(OutputInfoShort, "nclone"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(OutputInfoShort, "clones"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(OutputInfoShort, "nmode"));
    try std.testing.expectEqual(@as(usize, 84), @offsetOf(OutputInfoShort, "npreferred"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(OutputInfoShort, "modes"));

    // Variante com enums de 4 bytes (xorgproto antigo): 104 bytes.
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(OutputInfoEnum));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(OutputInfoEnum, "connection"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(OutputInfoEnum, "subpixel_order"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(OutputInfoEnum, "ncrtc"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(OutputInfoEnum, "crtcs"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(OutputInfoEnum, "nclone"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(OutputInfoEnum, "clones"));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(OutputInfoEnum, "nmode"));
    try std.testing.expectEqual(@as(usize, 92), @offsetOf(OutputInfoEnum, "npreferred"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(OutputInfoEnum, "modes"));
}

test "XRRCrtcInfo layout matches Xrandr.h (64-bit)" {
    if (@sizeOf(usize) != 8) return;
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CrtcInfo));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CrtcInfo, "timestamp"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CrtcInfo, "x"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(CrtcInfo, "y"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CrtcInfo, "width"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(CrtcInfo, "height"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CrtcInfo, "mode"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(CrtcInfo, "rotation"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(CrtcInfo, "noutput"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(CrtcInfo, "outputs"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(CrtcInfo, "rotations"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(CrtcInfo, "npossible"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(CrtcInfo, "possible"));
}

test "refresh rate is derived from dotClock and totals" {
    var mode: ModeInfo = std.mem.zeroes(ModeInfo);
    mode.dotClock = 148_500_000;
    mode.hTotal = 2_200;
    mode.vTotal = 1_125;
    // 148.5MHz / (2200 * 1125) = 60Hz
    try std.testing.expectEqual(@as(u32, 60_000), Lib.refreshMilliHz(&mode));

    mode.dotClock = 0;
    try std.testing.expectEqual(@as(u32, 0), Lib.refreshMilliHz(&mode));
}
