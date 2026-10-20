// Carregamento dinamico opcional de libXrandr (RandR 1.5+).
//
// Nao ha dependencia de link: a biblioteca e procurada em runtime. Sem
// libXrandr (ou sem RandR 1.5 no servidor), o backend X11 cai para a
// enumeracao de X screens. A ABI e declarada manualmente aqui, conforme
// a politica do projeto (sem @cImport/headers C).
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
const GetMonitorsFn = *const fn (
    *api.Display,
    api.Window,
    api.XBool,
    *c_int,
) callconv(.c) ?[*]MonitorInfo;
const FreeMonitorsFn = *const fn ([*]MonitorInfo) callconv(.c) void;

/// Handle e simbolos de libXrandr. Mantido vivo enquanto o display X
/// estiver aberto.
pub const Lib = struct {
    dyn: std.DynLib,
    query_version: QueryVersionFn,
    get_monitors: GetMonitorsFn,
    free_monitors: FreeMonitorsFn,

    /// Tenta carregar libXrandr e resolver a API de monitores (1.5+).
    /// Retorna null se a biblioteca ou algum simbolo nao existir.
    pub fn load() ?Lib {
        var dyn = std.DynLib.open("libXrandr.so.2") catch blk: {
            break :blk std.DynLib.open("libXrandr.so") catch return null;
        };
        const query_version = dyn.lookup(QueryVersionFn, "XRRQueryVersion") orelse {
            dyn.close();
            return null;
        };
        const get_monitors = dyn.lookup(GetMonitorsFn, "XRRGetMonitors") orelse {
            dyn.close();
            return null;
        };
        const free_monitors = dyn.lookup(FreeMonitorsFn, "XRRFreeMonitors") orelse {
            dyn.close();
            return null;
        };
        return .{
            .dyn = dyn,
            .query_version = query_version,
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
        var major: c_int = 0;
        var minor: c_int = 0;
        if (self.query_version(display, &major, &minor) == 0) return false;
        return major > 1 or (major == 1 and minor >= 5);
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
        var count: c_int = 0;
        const ptr = self.get_monitors(display, root, api.True, &count) orelse return null;
        defer self.free_monitors(ptr);
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
