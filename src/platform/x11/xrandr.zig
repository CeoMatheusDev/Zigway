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
        return .{
            .dyn = dyn,
            .query_version = query_version,
            .query_extension = query_extension,
            .select_input = select_input,
            .update_configuration = update_configuration,
            .get_monitors = get_monitors,
            .free_monitors = free_monitors,
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
