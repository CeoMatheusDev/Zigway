// Zigway Win32: backend sobre user32/kernel32 (declaracoes em api.zig).
//
// Roteamento: o ponteiro *Backend viaja em lpCreateParams e e guardado em
// GWLP_USERDATA no WM_NCCREATE. Como o despacho de mensagens e sincrono,
// o trio (registro, fila, input) e publicado em `pending` antes de cada
// chamada que pode despachar (create/destroy/poll).
//
// Semantica de fechamento: WM_CLOSE gera apenas o evento `close`; a
// janela sobrevive ate `destroyWindow` (ver Platform). Nao ha PostQuitMessage.

const std = @import("std");
const api = @import("api.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");

const Entry = struct {
    slot: u32,
    hwnd: api.HWND,
    cursor: types.Cursor = .default,
    /// Limites aplicados em `WM_GETMINMAXINFO`.
    size_limits: types.WindowSizeLimits = .{},
    /// Retangulo externo e estilo anteriores ao fullscreen.
    saved_fullscreen: ?api.RECT = null,
    saved_style: usize = 0,
    /// Surrogate alto (UTF-16) aguardando a parte baixa.
    pending_high_surrogate: u16 = 0,
};

const Pending = struct {
    reg: *registry.Registry,
    queue: ?*events.EventQueue,
    state: ?*input.InputState,
};

/// Contexto da enumeracao de monitores. O callback do user32 nao pode
/// propagar erros; a falha de alocacao fica em `err` e interrompe a
/// enumeracao.
const DisplayCollector = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(types.DisplayInfo) = .empty,
    err: ?anyerror = null,
};

fn collectMonitor(
    monitor: api.HMONITOR,
    hdc: api.HDC,
    rect: *api.RECT,
    data: api.LPARAM,
) callconv(.winapi) api.BOOL {
    _ = hdc;
    _ = rect;
    const ctx: *DisplayCollector = @ptrFromInt(@as(usize, @bitCast(data)));
    var info = api.MONITORINFO{
        .cbSize = @sizeOf(api.MONITORINFO),
        .rcMonitor = std.mem.zeroes(api.RECT),
        .rcWork = std.mem.zeroes(api.RECT),
        .dwFlags = 0,
    };
    if (api.GetMonitorInfoW(monitor, &info) == 0) return 1;
    const width = info.rcMonitor.right - info.rcMonitor.left;
    const height = info.rcMonitor.bottom - info.rcMonitor.top;
    if (width <= 0 or height <= 0) return 1;
    const display = types.DisplayInfo{
        .id = .{ .raw = @intCast(ctx.list.items.len) },
        .x = info.rcMonitor.left,
        .y = info.rcMonitor.top,
        .width = @intCast(width),
        .height = @intCast(height),
        .primary = (info.dwFlags & api.MONITORINFOF_PRIMARY) != 0,
    };
    ctx.list.append(ctx.allocator, display) catch |err| {
        ctx.err = err;
        return 0;
    };
    return 1;
}

/// Contexto da enumeracao de dispositivos de display. A ordem e a mesma
/// de `displays` (ambos usam `EnumDisplayMonitors`), entao o indice do
/// snapshot corresponde ao indice do dispositivo.
const DeviceCollector = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList([api.CCHDEVICENAME]u16) = .empty,
    err: ?anyerror = null,
};

fn collectDevice(
    monitor: api.HMONITOR,
    hdc: api.HDC,
    rect: *api.RECT,
    data: api.LPARAM,
) callconv(.winapi) api.BOOL {
    _ = hdc;
    _ = rect;
    const ctx: *DeviceCollector = @ptrFromInt(@as(usize, @bitCast(data)));
    var info = api.MONITORINFOEXW{
        .cbSize = @sizeOf(api.MONITORINFOEXW),
        .rcMonitor = std.mem.zeroes(api.RECT),
        .rcWork = std.mem.zeroes(api.RECT),
        .dwFlags = 0,
        .szDevice = std.mem.zeroes([api.CCHDEVICENAME]u16),
    };
    // `GetMonitorInfoW` preenche `szDevice` quando `cbSize` e o de
    // `MONITORINFOEXW`; o ponteiro e convertido porque o prefixo e igual.
    if (api.GetMonitorInfoW(monitor, @ptrCast(&info)) == 0) return 1;
    // Mesmo filtro de `collectMonitor`: mantendo a mesma ordem e os mesmos
    // indices, o `DisplayId` do snapshot corresponde ao dispositivo.
    const width = info.rcMonitor.right - info.rcMonitor.left;
    const height = info.rcMonitor.bottom - info.rcMonitor.top;
    if (width <= 0 or height <= 0) return 1;
    var terminated = false;
    for (&info.szDevice) |*ch| {
        if (ch.* == 0) {
            terminated = true;
            break;
        }
    }
    if (!terminated) info.szDevice[api.CCHDEVICENAME - 1] = 0;
    ctx.list.append(ctx.allocator, info.szDevice) catch |err| {
        ctx.err = err;
        return 0;
    };
    return 1;
}

/// Identificador de modo do Win32 empacotado em `u64`:
/// largura (16 bits) | altura (16 bits) | indice do modo (32 bits).
/// O indice e o de `EnumDisplaySettingsW`, valido enquanto a
/// configuracao do dispositivo nao mudar.
const DecodedModeId = struct {
    width: u32,
    height: u32,
    index: u32,
};

fn packModeId(width: u32, height: u32, index: u32) u64 {
    return (@as(u64, width & 0xFFFF) << 48) |
        (@as(u64, height & 0xFFFF) << 32) |
        @as(u64, index);
}

fn unpackModeId(raw: u64) ?DecodedModeId {
    const width = (raw >> 48) & 0xFFFF;
    const height = (raw >> 32) & 0xFFFF;
    const index = raw & 0xFFFFFFFF;
    if (width == 0 or height == 0) return null;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .index = @intCast(index),
    };
}

/// Converte uma unidade UTF-16 em codepoint Unicode, combinando pares
/// substitutos. `pending_high` guarda o surrogate alto entre chamadas.
/// Retorna null quando a unidade nao completa um texto (surrogate alto
/// ou baixo sem par).
fn utf16ToCodepoint(unit: u16, pending_high: *u16) ?u32 {
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        pending_high.* = unit;
        return null;
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        const high = pending_high.*;
        pending_high.* = 0;
        if (high == 0) return null;
        return 0x10000 + ((@as(u32, high - 0xD800) << 10) | @as(u32, unit - 0xDC00));
    }
    pending_high.* = 0;
    return unit;
}

/// Contador global para nomes de classe unicos por instancia Backend.
/// Multiplas Platforms no mesmo processo sao suportadas; cada uma
/// registra sua propria classe (o segundo RegisterClassExW com nome
/// repetido falharia).
var class_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub const max_class_name: usize = 32;

const class_prefix = "ZigwayWindow#";

/// Gera `ZigwayWindow#<counter>` em UTF-16 com sentinela. Pura e
/// testavel sem SO (o contador global so existe no init).
pub fn formatClassName(counter: u32, out: *[max_class_name:0]u16) void {
    var i: usize = 0;
    for (class_prefix) |c| {
        out[i] = c;
        i += 1;
    }
    // Digitos decimais via buffer temporario invertido.
    var digits: [10]u16 = undefined;
    var n_digits: usize = 0;
    var n = counter;
    if (n == 0) {
        digits[0] = '0';
        n_digits = 1;
    } else {
        while (n > 0) {
            digits[n_digits] = '0' + @as(u16, @intCast(n % 10));
            n_digits += 1;
            n /= 10;
        }
    }
    var j = n_digits;
    while (j > 0) {
        j -= 1;
        out[i] = digits[j];
        i += 1;
    }
    out[i] = 0;
}

pub const Backend = struct {
    allocator: std.mem.Allocator,
    /// Evento manual de wakeup (acorda `waitEvents`).
    wake_event: ?*anyopaque = null,
    instance: api.HINSTANCE,
    class_atom: api.ATOM,
    class_name: [max_class_name:0]u16 = undefined,
    entries: std.ArrayList(Entry) = .empty,
    /// Slot da janela com captura de mouse (por thread no Win32), se houver.
    captured: ?u32 = null,
    pending: ?Pending = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        var self = Backend{
            .allocator = allocator,
            .instance = api.GetModuleHandleW(null),
            .class_atom = 0,
        };
        const id = class_counter.fetchAdd(1, .monotonic);
        formatClassName(id, &self.class_name);
        const cls = api.WNDCLASSEXW{
            .cbSize = @sizeOf(api.WNDCLASSEXW),
            .style = api.CS_HREDRAW | api.CS_VREDRAW | api.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.instance,
            .hIcon = null,
            .hCursor = api.LoadCursorW(null, api.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = @ptrCast(&self.class_name),
            .hIconSm = null,
        };
        const atom = api.RegisterClassExW(&cls);
        if (atom == 0) return error.ConnectionFailed;
        self.class_atom = atom;
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (self.captured) |slot| {
            if (self.findEntry(slot)) |i| {
                if (api.GetCapture() == self.entries.items[i].hwnd) _ = api.ReleaseCapture();
            }
        }
        if (self.wake_event) |event| {
            _ = api.CloseHandle(event);
            self.wake_event = null;
        }
        self.entries.deinit(self.allocator);
        _ = api.UnregisterClassW(@ptrCast(&self.class_name), self.instance);
    }

    /// Snapshot dos monitores via EnumDisplayMonitors/GetMonitorInfoW.
    /// Retorna OutOfMemory se a lista nao puder ser construida.
    pub fn displays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        _ = self;
        var ctx = DisplayCollector{ .allocator = allocator };
        defer ctx.list.deinit(allocator);
        const ok = api.EnumDisplayMonitors(
            null,
            null,
            collectMonitor,
            @bitCast(@intFromPtr(&ctx)),
        );
        if (ctx.err) |err| return err;
        if (ok == 0) return error.ConnectionFailed;
        return ctx.list.toOwnedSlice(allocator);
    }

    /// Modos de video de um display (`EnumDisplaySettingsW`).
    ///
    /// O `DisplayId` precisa vir do snapshot de `displays`; o indice do
    /// snapshot corresponde ao dispositivo na ordem de `EnumDisplayMonitors`.
    pub fn displayModes(
        self: *const Backend,
        allocator: std.mem.Allocator,
        id: types.DisplayId,
    ) ![]types.DisplayMode {
        const devices = try self.displayDevices(allocator);
        defer allocator.free(devices);
        if (id.raw >= devices.len) return error.InvalidDisplay;
        var device = devices[id.raw];
        const device_ptr: [*:0]const u16 = @ptrCast(&device);

        // Modo corrente: referencia para marcar `current`.
        var current: api.DEVMODEW = std.mem.zeroes(api.DEVMODEW);
        current.dmSize = @sizeOf(api.DEVMODEW);
        const have_current = api.EnumDisplaySettingsW(
            device_ptr,
            api.ENUM_CURRENT_SETTINGS,
            &current,
        ) != 0;

        var list: std.ArrayList(types.DisplayMode) = .empty;
        defer list.deinit(allocator);

        var index: api.DWORD = 0;
        while (index < 512) : (index += 1) {
            var dm: api.DEVMODEW = std.mem.zeroes(api.DEVMODEW);
            dm.dmSize = @sizeOf(api.DEVMODEW);
            if (api.EnumDisplaySettingsW(device_ptr, index, &dm) == 0) break;
            const width = dm.dmPelsWidth;
            const height = dm.dmPelsHeight;
            if (width == 0 or height == 0) continue;
            // O id empacota 16 bits por eixo.
            if (width > 0xFFFF or height > 0xFFFF) continue;
            // 0/1 significam "padrao do driver" (frequencia desconhecida).
            const refresh_mhz: u32 = if (dm.dmDisplayFrequency > 1)
                dm.dmDisplayFrequency * 1000
            else
                0;
            const is_current = have_current and
                dm.dmPelsWidth == current.dmPelsWidth and
                dm.dmPelsHeight == current.dmPelsHeight and
                (refresh_mhz == 0 or current.dmDisplayFrequency == dm.dmDisplayFrequency);
            try list.append(allocator, .{
                .id = .{ .raw = packModeId(width, height, index) },
                .width = width,
                .height = height,
                .refresh_mhz = refresh_mhz,
                .current = is_current,
                // O Win32 nao sinaliza um modo "preferido" no DEVMODE.
                .preferred = false,
            });
        }
        return try list.toOwnedSlice(allocator);
    }

    /// Aplica um modo de video (`ChangeDisplaySettingsExW`). A troca e
    /// dinamica: nao grava no registro e vale ate a proxima troca.
    pub fn setDisplayMode(
        self: *const Backend,
        id: types.DisplayId,
        mode: types.DisplayModeId,
    ) !void {
        const decoded = unpackModeId(mode.raw) orelse return error.InvalidDisplayMode;
        const devices = try self.displayDevices(self.allocator);
        defer self.allocator.free(devices);
        if (id.raw >= devices.len) return error.InvalidDisplay;
        var device = devices[id.raw];
        const device_ptr: [*:0]const u16 = @ptrCast(&device);

        var dm: api.DEVMODEW = std.mem.zeroes(api.DEVMODEW);
        dm.dmSize = @sizeOf(api.DEVMODEW);
        if (api.EnumDisplaySettingsW(device_ptr, decoded.index, &dm) == 0) {
            return error.InvalidDisplayMode;
        }
        // O indice pode ter mudado de geometria se a configuracao do
        // dispositivo mudou desde o snapshot.
        if (dm.dmPelsWidth != decoded.width or dm.dmPelsHeight != decoded.height) {
            return error.InvalidDisplayMode;
        }
        const result = api.ChangeDisplaySettingsExW(device_ptr, &dm, null, null, null);
        if (result != api.DISP_CHANGE_SUCCESSFUL) return error.DisplayModeFailed;
    }

    /// O Win32 suporta posicionamento, clipboard, IME (via `WM_CHAR`),
    /// cursor do sistema, captura de ponteiro e modos de video.
    pub fn capabilities(self: *const Backend) types.Capabilities {
        _ = self;
        return .{
            .absolute_positioning = true,
            .resize_request = true,
            .focus_request = true,
            .clipboard = true,
            .text_input_ime = true,
            .system_cursor = true,
            .pointer_capture = true,
            .pointer_relative = false,
            .pointer_confinement = false,
            .fractional_scale = false,
            .video_modes = true,
            .seat = false,
        };
    }

    /// O Win32 nao expoe a composicao do IME (apenas o texto
    /// confirmado, via `WM_CHAR`).
    pub fn compositionText(self: *const Backend, reg: *registry.Registry, id: types.WindowId) ?[]const u8 {
        _ = self;
        _ = reg;
        _ = id;
        return null;
    }

    /// O Win32 nao modela um seat (o input e por janela).
    pub fn seatCapabilities(self: *const Backend) ?types.SeatCapabilities {
        _ = self;
        return null;
    }

    // --- Area de transferencia (clipboard) ---

    /// Limite de 1 MiB por texto na area de transferencia.
    pub const max_clipboard_bytes: usize = 1 << 20;

    /// Define o texto (UTF-8) da area de transferencia. O conteudo e
    /// gravado como `CF_UNICODETEXT` (UTF-16).
    pub fn setClipboardText(self: *Backend, text: []const u8) !void {
        if (text.len > max_clipboard_bytes) return error.InvalidConfig;
        const wide = std.unicode.utf8ToUtf16LeAlloc(self.allocator, text) catch |err| switch (err) {
            error.InvalidUtf8 => return error.InvalidConfig,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(wide);
        const with_nul = try self.allocator.alloc(u16, wide.len + 1);
        defer self.allocator.free(with_nul);
        @memcpy(with_nul[0..wide.len], wide);
        with_nul[wide.len] = 0;

        if (api.OpenClipboard(null) == 0) return error.ClipboardFailed;
        defer _ = api.CloseClipboard();
        if (api.EmptyClipboard() == 0) return error.ClipboardFailed;

        const handle = api.GlobalAlloc(api.GMEM_MOVEABLE, with_nul.len * 2) orelse
            return error.ClipboardFailed;
        const ptr = api.GlobalLock(handle) orelse {
            _ = api.GlobalFree(handle);
            return error.ClipboardFailed;
        };
        @memcpy(@as([*]u16, @ptrCast(@alignCast(ptr)))[0..with_nul.len], with_nul);
        _ = api.GlobalUnlock(handle);
        if (api.SetClipboardData(api.CF_UNICODETEXT, handle) == null) {
            // O sistema nao assumiu a posse: libera o bloco.
            _ = api.GlobalFree(handle);
            return error.ClipboardFailed;
        }
    }

    /// Texto (UTF-8) da area de transferencia. `null` quando vazia ou
    /// quando nao ha texto Unicode.
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
        if (api.OpenClipboard(null) == 0) return error.ClipboardFailed;
        defer _ = api.CloseClipboard();
        const handle = api.GetClipboardData(api.CF_UNICODETEXT) orelse return null;
        const ptr = api.GlobalLock(handle) orelse return null;
        defer _ = api.GlobalUnlock(handle);
        const wide: [*:0]const u16 = @ptrCast(@alignCast(ptr));
        const len = std.mem.len(wide);
        if (len == 0) return null;
        return try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..len]);
    }

    /// Dispositivos de display na ordem do snapshot de `displays`.
    fn displayDevices(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![][api.CCHDEVICENAME]u16 {
        _ = self;
        var ctx = DeviceCollector{ .allocator = allocator };
        defer ctx.list.deinit(allocator);
        const ok = api.EnumDisplayMonitors(
            null,
            null,
            collectDevice,
            @bitCast(@intFromPtr(&ctx)),
        );
        if (ctx.err) |err| return err;
        if (ok == 0) return error.ConnectionFailed;
        return ctx.list.toOwnedSlice(allocator);
    }

    fn findEntry(self: *const Backend, slot: u32) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.slot == slot) return i;
        }
        return null;
    }

    fn findEntryByHwnd(self: *const Backend, hwnd: api.HWND) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.hwnd == hwnd) return i;
        }
        return null;
    }

    fn slotOfNative(self: *const Backend, reg: *registry.Registry, hwnd: api.HWND) ?u32 {
        for (self.entries.items) |entry| {
            if (entry.hwnd == hwnd) {
                if (entry.slot < reg.slots.items.len and
                    reg.slots.items[entry.slot].occupied)
                {
                    return entry.slot;
                }
                return null;
            }
        }
        return null;
    }

    fn styleFor(resizable: bool) api.DWORD {
        return if (resizable) api.WS_OVERLAPPEDWINDOW else api.WS_OVERLAPPED_NONRESIZABLE;
    }

    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        var title_buf: [2049:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(title_buf[0..2048], cfg.title) catch
            return error.InvalidConfig;
        title_buf[title_len] = 0;

        const style = styleFor(cfg.resizable);
        var rect = api.RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(cfg.width),
            .bottom = @intCast(cfg.height),
        };
        if (api.AdjustWindowRectEx(&rect, style, 0, 0) == 0) return error.WindowCreationFailed;

        // Mensagens de criacao (WM_NCCREATE/CREATE/SIZE) chegam de forma
        // sincrona; sem entrada no registro ainda, sao ignoradas.
        self.pending = .{ .reg = reg, .queue = null, .state = null };
        const hwnd = api.CreateWindowExW(
            0,
            @ptrCast(&self.class_name),
            @ptrCast(&title_buf),
            style,
            @as(c_int, @bitCast(@as(u32, 0x80000000))), // CW_USEDEFAULT
            @as(c_int, @bitCast(@as(u32, 0x80000000))),
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            self.instance,
            self,
        );
        self.pending = null;
        if (hwnd == null) return error.WindowCreationFailed;
        errdefer _ = api.DestroyWindow(hwnd);

        try self.entries.append(self.allocator, .{ .slot = slot, .hwnd = hwnd });
        reg.slots.items[slot].native_ptr = hwnd;
        // CW_USEDEFAULT: a posicao inicial nao e conhecida ate consultar.
        var client = api.POINT{ .x = 0, .y = 0 };
        if (api.ClientToScreen(hwnd, &client) != 0) {
            reg.slots.items[slot].x = client.x;
            reg.slots.items[slot].y = client.y;
        }

        if (cfg.visible) _ = api.ShowWindow(hwnd, api.SW_SHOW);
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        // Libera a captura antes de remover a entrada/destruir a janela.
        self.releasePointer(reg, slot);
        if (self.findEntry(slot)) |i| {
            const hwnd = self.entries.items[i].hwnd;
            _ = self.entries.swapRemove(i);
            self.pending = .{ .reg = reg, .queue = null, .state = null };
            _ = api.DestroyWindow(hwnd);
            self.pending = null;
        }
    }

    pub fn setTitle(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        title: []const u8,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        var title_buf: [2049:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(title_buf[0..2048], title) catch
            return error.InvalidConfig;
        title_buf[title_len] = 0;
        _ = api.SetWindowTextW(self.entries.items[entry_idx].hwnd, @ptrCast(&title_buf));
    }

    pub fn setSize(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        width: u32,
        height: u32,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const hwnd = self.entries.items[entry_idx].hwnd;
        const style_bits: usize = @bitCast(api.GetWindowLongPtrW(hwnd, api.GWL_STYLE));
        const style: api.DWORD = @truncate(style_bits);
        var rect = api.RECT{
            .left = 0,
            .top = 0,
            .right = @intCast(width),
            .bottom = @intCast(height),
        };
        if (api.AdjustWindowRectEx(&rect, style, 0, 0) == 0) return error.WindowCreationFailed;
        _ = api.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            rect.right - rect.left,
            rect.bottom - rect.top,
            api.SWP_NOMOVE | api.SWP_NOZORDER,
        );
        // Confirmacao chega via WM_SIZE.
    }

    /// Move a origem da area de cliente para (x, y) em coordenadas de
    /// tela. `SetWindowPos` posiciona a janela externa; o delta entre a
    /// origem externa e a origem do cliente e preservado.
    pub fn setPosition(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        x: i32,
        y: i32,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const hwnd = self.entries.items[entry_idx].hwnd;
        var rect: api.RECT = undefined;
        if (api.GetWindowRect(hwnd, &rect) == 0) return error.WindowMoveFailed;
        var client = api.POINT{ .x = 0, .y = 0 };
        if (api.ClientToScreen(hwnd, &client) == 0) return error.WindowMoveFailed;
        // Calcula em i64: coordenadas arbitrarias de entrada nao podem
        // causar overflow ao somar o delta da decoracao.
        const outer_x_wide: i64 = @as(i64, rect.left) + (@as(i64, x) - @as(i64, client.x));
        const outer_y_wide: i64 = @as(i64, rect.top) + (@as(i64, y) - @as(i64, client.y));
        if (outer_x_wide < std.math.minInt(c_int) or outer_x_wide > std.math.maxInt(c_int) or
            outer_y_wide < std.math.minInt(c_int) or outer_y_wide > std.math.maxInt(c_int))
        {
            return error.WindowMoveFailed;
        }
        const outer_x: c_int = @intCast(outer_x_wide);
        const outer_y: c_int = @intCast(outer_y_wide);
        if (api.SetWindowPos(
            hwnd,
            null,
            outer_x,
            outer_y,
            0,
            0,
            api.SWP_NOSIZE | api.SWP_NOZORDER | api.SWP_NOACTIVATE,
        ) == 0) return error.WindowMoveFailed;

        // WM_MOVE durante SetWindowPos pode ter sido ignorado (sem
        // pending); confirma pela posicao real e evita evento duplicado.
        if (api.ClientToScreen(hwnd, &client) != 0) {
            const entry = &reg.slots.items[slot];
            if (entry.x != client.x or entry.y != client.y) {
                entry.x = client.x;
                entry.y = client.y;
                events.dispatch(queue, state, .{ .move = .{
                    .window = reg.idOf(slot),
                    .x = client.x,
                    .y = client.y,
                } });
            }
        }
    }

    pub fn setSizeLimits(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        limits: types.WindowSizeLimits,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        self.entries.items[entry_idx].size_limits = limits;
    }

    /// Fullscreen sem borda sobre o monitor mais proximo. O estado e
    /// controlado pela aplicacao (nao ha notificacao nativa equivalente).
    pub fn setFullscreen(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        fullscreen: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const hwnd = self.entries.items[entry_idx].hwnd;
        const slot_state = &reg.slots.items[slot];
        if (slot_state.fullscreen == fullscreen) return;
        if (fullscreen and slot_state.maximized) return error.WindowStateFailed;

        if (fullscreen) {
            var saved: api.RECT = undefined;
            if (api.GetWindowRect(hwnd, &saved) == 0) return error.WindowStateFailed;
            const style_bits: usize = @bitCast(api.GetWindowLongPtrW(hwnd, api.GWL_STYLE));
            const style: api.DWORD = @truncate(style_bits);
            const monitor = api.MonitorFromWindow(hwnd, api.MONITOR_DEFAULTTONEAREST) orelse
                return error.WindowStateFailed;
            var info = api.MONITORINFO{
                .cbSize = @sizeOf(api.MONITORINFO),
                .rcMonitor = std.mem.zeroes(api.RECT),
                .rcWork = std.mem.zeroes(api.RECT),
                .dwFlags = 0,
            };
            if (api.GetMonitorInfoW(monitor, &info) == 0) return error.WindowStateFailed;
            const width = info.rcMonitor.right - info.rcMonitor.left;
            const height = info.rcMonitor.bottom - info.rcMonitor.top;
            if (width <= 0 or height <= 0) return error.WindowStateFailed;

            const new_style: api.DWORD =
                (style & ~api.WS_OVERLAPPEDWINDOW) | api.WS_POPUP;
            const new_style_param: api.LPARAM = @bitCast(@as(usize, new_style));
            _ = api.SetWindowLongPtrW(hwnd, api.GWL_STYLE, new_style_param);
            if (api.SetWindowPos(
                hwnd,
                null,
                info.rcMonitor.left,
                info.rcMonitor.top,
                width,
                height,
                api.SWP_FRAMECHANGED | api.SWP_NOZORDER | api.SWP_NOACTIVATE,
            ) == 0) {
                // Desfaz o estilo para nao deixar a janela sem borda.
                _ = api.SetWindowLongPtrW(hwnd, api.GWL_STYLE, @bitCast(style_bits));
                _ = api.SetWindowPos(
                    hwnd,
                    null,
                    saved.left,
                    saved.top,
                    saved.right - saved.left,
                    saved.bottom - saved.top,
                    api.SWP_FRAMECHANGED | api.SWP_NOZORDER | api.SWP_NOACTIVATE,
                );
                return error.WindowStateFailed;
            }
            const entry = &self.entries.items[entry_idx];
            entry.saved_fullscreen = saved;
            entry.saved_style = style_bits;
            slot_state.fullscreen = true;
            self.syncClientGeometry(reg, queue, state, slot, hwnd);
            events.dispatch(queue, state, .{ .fullscreen = .{
                .window = reg.idOf(slot),
                .fullscreen = true,
            } });
            return;
        }

        const entry = &self.entries.items[entry_idx];
        const saved = entry.saved_fullscreen orelse {
            slot_state.fullscreen = false;
            return;
        };
        const width = saved.right - saved.left;
        const height = saved.bottom - saved.top;
        if (width <= 0 or height <= 0) return error.WindowStateFailed;
        const current_style_bits: usize = @bitCast(api.GetWindowLongPtrW(hwnd, api.GWL_STYLE));
        _ = api.SetWindowLongPtrW(hwnd, api.GWL_STYLE, @bitCast(entry.saved_style));
        if (api.SetWindowPos(
            hwnd,
            null,
            saved.left,
            saved.top,
            width,
            height,
            api.SWP_FRAMECHANGED | api.SWP_NOZORDER | api.SWP_NOACTIVATE,
        ) == 0) {
            _ = api.SetWindowLongPtrW(hwnd, api.GWL_STYLE, @bitCast(current_style_bits));
            return error.WindowStateFailed;
        }
        entry.saved_fullscreen = null;
        entry.saved_style = 0;
        slot_state.fullscreen = false;
        self.syncClientGeometry(reg, queue, state, slot, hwnd);
        events.dispatch(queue, state, .{ .fullscreen = .{
            .window = reg.idOf(slot),
            .fullscreen = false,
        } });
    }

    pub fn isFullscreen(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = self;
        if (slot >= reg.slots.items.len or !reg.slots.items[slot].occupied) return false;
        return reg.slots.items[slot].fullscreen;
    }

    /// Maximiza/restaura via `ShowWindow`; o estado nativo e confirmado por
    /// `IsZoomed`. Fullscreen e maximizado sao mutuamente exclusivos.
    pub fn setMaximized(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        maximized: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const hwnd = self.entries.items[entry_idx].hwnd;
        const slot_state = &reg.slots.items[slot];
        if (maximized and slot_state.fullscreen) return error.WindowStateFailed;

        const native_now = api.IsZoomed(hwnd) != 0;
        if (native_now == maximized) {
            if (slot_state.maximized != maximized) {
                slot_state.maximized = maximized;
                self.syncClientGeometry(reg, queue, state, slot, hwnd);
                events.dispatch(queue, state, .{ .maximized = .{
                    .window = reg.idOf(slot),
                    .maximized = maximized,
                } });
            }
            return;
        }

        _ = api.ShowWindow(hwnd, if (maximized) api.SW_MAXIMIZE else api.SW_RESTORE);
        const now = api.IsZoomed(hwnd) != 0;
        if (now != maximized) return error.WindowStateFailed;
        const changed = slot_state.maximized != now;
        slot_state.maximized = now;
        self.syncClientGeometry(reg, queue, state, slot, hwnd);
        if (changed) {
            events.dispatch(queue, state, .{ .maximized = .{
                .window = reg.idOf(slot),
                .maximized = now,
            } });
        }
    }

    pub fn isMaximized(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = self;
        if (slot >= reg.slots.items.len or !reg.slots.items[slot].occupied) return false;
        return reg.slots.items[slot].maximized;
    }

    /// Atualiza posicao/tamanho do cliente e emite move/resize quando
    /// `SetWindowPos` mudou a geometria com `pending` nulo (mensagens
    /// sincronas ignoradas pelo WndProc).
    fn syncClientGeometry(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        hwnd: api.HWND,
    ) void {
        _ = self;
        var client = api.POINT{ .x = 0, .y = 0 };
        if (api.ClientToScreen(hwnd, &client) != 0) {
            const entry = &reg.slots.items[slot];
            if (entry.x != client.x or entry.y != client.y) {
                entry.x = client.x;
                entry.y = client.y;
                events.dispatch(queue, state, .{ .move = .{
                    .window = reg.idOf(slot),
                    .x = client.x,
                    .y = client.y,
                } });
            }
        }
        var rect: api.RECT = undefined;
        if (api.GetClientRect(hwnd, &rect) != 0) {
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;
            if (width > 0 and height > 0) {
                const entry = &reg.slots.items[slot];
                const w: u32 = @intCast(width);
                const h: u32 = @intCast(height);
                if (entry.width != w or entry.height != h) {
                    entry.width = w;
                    entry.height = h;
                    events.dispatch(queue, state, .{ .resize = .{
                        .window = reg.idOf(slot),
                        .width = w,
                        .height = h,
                    } });
                }
            }
        }
    }

    pub fn position(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) types.WindowPosition {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return .{ .x = 0, .y = 0 };
        var client = api.POINT{ .x = 0, .y = 0 };
        if (api.ClientToScreen(self.entries.items[entry_idx].hwnd, &client) == 0) {
            return .{ .x = 0, .y = 0 };
        }
        return .{ .x = client.x, .y = client.y };
    }

    pub fn setVisible(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        visible: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        _ = api.ShowWindow(
            self.entries.items[entry_idx].hwnd,
            if (visible) api.SW_SHOW else api.SW_HIDE,
        );
        reg.slots.items[slot].visible = visible;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        _ = api.SetFocus(self.entries.items[entry_idx].hwnd);
    }

    pub fn setCursor(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cursor: types.Cursor,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const handle = loadCursor(cursor);
        if (handle == null) return error.CursorCreationFailed;
        self.entries.items[entry_idx].cursor = cursor;
        _ = api.SetCursor(handle);
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const hwnd = self.entries.items[entry_idx].hwnd;
        if (api.GetCapture() == hwnd) {
            self.captured = slot;
            return;
        }
        // Transfere com a mesma semantica do X11: solta a anterior antes
        // de tentar a nova. Se a nova falhar, nenhuma fica capturada.
        if (self.captured) |old_slot| self.releasePointer(reg, old_slot);
        _ = api.SetCapture(hwnd);
        // SetCapture pode falhar se outra thread detem a captura.
        if (api.GetCapture() != hwnd) return error.PointerCaptureFailed;
        self.captured = slot;
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured != slot) return;
        const entry_idx = self.findEntry(slot) orelse {
            self.captured = null;
            return;
        };
        if (api.GetCapture() == self.entries.items[entry_idx].hwnd) {
            _ = api.ReleaseCapture();
        }
        self.captured = null;
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        self.pending = .{ .reg = reg, .queue = queue, .state = state };
        defer self.pending = null;
        var msg: api.MSG = undefined;
        while (api.PeekMessageW(&msg, null, 0, 0, api.PM_REMOVE) != 0) {
            _ = api.DispatchMessageW(&msg);
        }
    }

    /// Espera ate haver mensagem na fila ou o timeout expirar.
    ///
    /// O evento de wakeup permite que outra thread acorde o loop
    /// (`MsgWaitForMultipleObjects`), sem busy-wait.
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
        self.ensureWakeEvent();
        const event = self.wake_event orelse {
            self.poll(reg, queue, state);
            return 0;
        };
        var handles = [_]?*anyopaque{event};
        const timeout: api.DWORD = if (timeout_ms < 0)
            0xFFFFFFFF // INFINITE
        else
            @intCast(timeout_ms);
        const result = api.MsgWaitForMultipleObjects(
            1,
            &handles,
            0, // nao espera todos
            timeout,
            api.QS_ALLINPUT,
        );
        if (result == api.WAIT_TIMEOUT) return 0;
        if (result == api.WAIT_OBJECT_0) {
            // Wakeup: consome o evento e nao despacha mensagens.
            _ = api.ResetEvent(event);
            return 0;
        }
        // Ha mensagens: despacha tudo.
        self.poll(reg, queue, state);
        return 1;
    }

    /// Acorda uma thread bloqueada em `waitEvents`.
    pub fn wakeup(self: *Backend) void {
        self.ensureWakeEvent();
        if (self.wake_event) |event| _ = api.SetEvent(event);
    }

    /// Cria (sob demanda) o evento manual de wakeup.
    fn ensureWakeEvent(self: *Backend) void {
        if (self.wake_event != null) return;
        self.wake_event = api.CreateEventW(null, 0, 0, null);
    }
};

fn backendFromHwnd(hwnd: api.HWND) ?*Backend {
    const raw = api.GetWindowLongPtrW(hwnd, api.GWLP_USERDATA);
    if (raw == 0) return null;
    const addr: usize = @bitCast(raw);
    return @ptrFromInt(addr);
}

fn wndProc(hwnd: api.HWND, msg: api.UINT, wparam: api.WPARAM, lparam: api.LPARAM) callconv(.winapi) api.LRESULT {
    if (msg == api.WM_NCCREATE) {
        const cs: *const api.CREATESTRUCT_HEAD = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |ctx| {
            const backend: *Backend = @ptrCast(@alignCast(ctx));
            _ = api.SetWindowLongPtrW(hwnd, api.GWLP_USERDATA, @bitCast(@intFromPtr(backend)));
        }
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const backend = backendFromHwnd(hwnd) orelse
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);

    // WM_SETCURSOR nao gera evento publico: trata antes do contexto de
    // despacho (pending), que pode estar nulo durante create/destroy.
    // LOWORD(lParam) == HTCLIENT: ponteiro sobre a area de cliente.
    if (msg == api.WM_SETCURSOR) {
        const hit: usize = @as(usize, @bitCast(lparam)) & 0xFFFF;
        if (hit == api.HTCLIENT) {
            if (backend.findEntryByHwnd(hwnd)) |idx| {
                if (loadCursor(backend.entries.items[idx].cursor)) |handle| {
                    _ = api.SetCursor(handle);
                    return 1; // TRUE: impede o DefWindowProc de usar a classe.
                }
            }
        }
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    // WM_GETMINMAXINFO pode chegar antes de pending (create/SetWindowPos)
    // e precisa consultar os limites armazenados na entrada nativa.
    if (msg == api.WM_GETMINMAXINFO) {
        if (lparam != 0) {
            if (backend.findEntryByHwnd(hwnd)) |idx| {
                const limits = backend.entries.items[idx].size_limits;
                if (limits.min_width > 0 or limits.min_height > 0 or
                    limits.max_width > 0 or limits.max_height > 0)
                {
                    // WM_GETMINMAXINFO trabalha com o tamanho externo
                    // (tracking size); a API expoe a area de cliente.
                    const style: api.DWORD = @truncate(@as(usize, @bitCast(
                        api.GetWindowLongPtrW(hwnd, api.GWL_STYLE),
                    )));
                    const ex_style: api.DWORD = @truncate(@as(usize, @bitCast(
                        api.GetWindowLongPtrW(hwnd, api.GWL_EXSTYLE),
                    )));
                    var frame = api.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                    if (api.AdjustWindowRectEx(&frame, style, 0, ex_style) != 0) {
                        const border_x: api.LONG = frame.right - frame.left;
                        const border_y: api.LONG = frame.bottom - frame.top;
                        const info: *api.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                        if (limits.min_width > 0) {
                            info.ptMinTrackSize.x = @as(api.LONG, @intCast(limits.min_width)) + border_x;
                        }
                        if (limits.min_height > 0) {
                            info.ptMinTrackSize.y = @as(api.LONG, @intCast(limits.min_height)) + border_y;
                        }
                        if (limits.max_width > 0) {
                            info.ptMaxTrackSize.x = @as(api.LONG, @intCast(limits.max_width)) + border_x;
                        }
                        if (limits.max_height > 0) {
                            info.ptMaxTrackSize.y = @as(api.LONG, @intCast(limits.max_height)) + border_y;
                        }
                    }
                }
            }
        }
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const pending = backend.pending orelse
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);
    // Despacho de eventos exige fila+estado (nulos durante create/destroy,
    // quando nenhuma mensagem gera evento publico).
    const queue = pending.queue orelse
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);
    const state = pending.state orelse
        return api.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        api.WM_CLOSE => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                events.dispatch(queue, state, .{
                    .close = .{ .window = pending.reg.idOf(slot) },
                });
            }
            return 0;
        },
        api.WM_DESTROY => {
            // Caminho proprio (destroyWindow) ja removeu a entrada: aqui
            // so chega destruicao externa. Remove a entrada para que
            // operacoes seguintes retornem InvalidWindow em vez de
            // atingir HWND invalida.
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                const wid = pending.reg.idOf(slot);
                pending.reg.slots.items[slot].should_close = true;
                // A destruicao da janela libera a captura no sistema.
                if (backend.captured == slot) backend.captured = null;
                events.dispatch(queue, state, .{
                    .close = .{ .window = wid },
                });
                if (backend.findEntry(slot)) |i| {
                    _ = backend.entries.swapRemove(i);
                }
            }
            return 0;
        },
        api.WM_DISPLAYCHANGE => {
            // Resolucao/color depth (e, na pratica, hotplug que altera o
            // desktop). Cada janela top-level recebe; o coalescing da fila
            // evita avisos adjacentes duplicados.
            events.dispatch(queue, state, .{ .display_change = .{} });
            return 0;
        },
        api.WM_MOVE => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                var client = api.POINT{ .x = 0, .y = 0 };
                if (api.ClientToScreen(hwnd, &client) != 0) {
                    const entry = &pending.reg.slots.items[slot];
                    if (entry.x != client.x or entry.y != client.y) {
                        entry.x = client.x;
                        entry.y = client.y;
                        events.dispatch(queue, state, .{ .move = .{
                            .window = pending.reg.idOf(slot),
                            .x = client.x,
                            .y = client.y,
                        } });
                    }
                }
            }
            return 0;
        },
        api.WM_SIZE => {
            if (wparam == api.SIZE_MINIMIZED) {
                if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                    pending.reg.slots.items[slot].visible = false;
                }
                return 0;
            }
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                if (wparam == api.SIZE_MAXIMIZED or wparam == api.SIZE_RESTORED) {
                    const now_maximized = wparam == api.SIZE_MAXIMIZED;
                    const slot_state = &pending.reg.slots.items[slot];
                    if (slot_state.maximized != now_maximized) {
                        slot_state.maximized = now_maximized;
                        events.dispatch(queue, state, .{ .maximized = .{
                            .window = pending.reg.idOf(slot),
                            .maximized = now_maximized,
                        } });
                    }
                }
                const bits: usize = @bitCast(lparam);
                const w: u32 = @as(u16, @truncate(bits));
                const h: u32 = @as(u16, @truncate(bits >> 16));
                const entry = &pending.reg.slots.items[slot];
                entry.visible = true;
                if (entry.width != w or entry.height != h) {
                    entry.width = w;
                    entry.height = h;
                    events.dispatch(queue, state, .{
                        .resize = .{ .window = pending.reg.idOf(slot), .width = w, .height = h },
                    });
                }
            }
            return 0;
        },
        api.WM_SETFOCUS => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                pending.reg.slots.items[slot].focused = true;
                events.dispatch(queue, state, .{
                    .focus = .{ .window = pending.reg.idOf(slot), .focused = true },
                });
            }
            return 0;
        },
        api.WM_KILLFOCUS => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                pending.reg.slots.items[slot].focused = false;
                const wid = pending.reg.idOf(slot);
                events.dispatch(queue, state, .{
                    .focus = .{ .window = wid, .focused = false },
                });
                // Solta o que estava pressionado: os ups correspondentes
                // nao serao entregues com outra janela focada.
                input.releaseAll(wid, queue, state);
            }
            return 0;
        },
        api.WM_KEYDOWN, api.WM_SYSKEYDOWN, api.WM_KEYUP, api.WM_SYSKEYUP => {
            const pressed = msg == api.WM_KEYDOWN or msg == api.WM_SYSKEYDOWN;
            const vk: u16 = @truncate(wparam);
            const key = fromVk(vk);
            const wid: ?types.WindowId = if (backend.slotOfNative(pending.reg, hwnd)) |slot|
                pending.reg.idOf(slot)
            else
                null;
            const bits: usize = @bitCast(lparam);
            const kev: events.KeyEvent = .{
                .window = wid,
                .key = key,
                .modifiers = currentMods(),
                .repeat = pressed and ((bits >> 30) & 1) == 1,
            };
            if (pressed) {
                events.dispatch(queue, state, .{ .key_down = kev });
            } else {
                events.dispatch(queue, state, .{ .key_up = kev });
            }
            // Input bruto: o scan code (bits 16-23 do lparam) identifica
            // a tecla fisica (Shift esquerdo/direito, etc.).
            if (wid) |window_id| {
                const scancode: u32 = @intCast((bits >> 16) & 0xFF);
                events.dispatch(queue, state, .{ .raw_key = .{
                    .window = window_id,
                    .scancode = scancode,
                    .pressed = pressed,
                    .modifiers = currentMods(),
                } });
            }
            return 0;
        },
        api.WM_CHAR => {
            // Texto ja composto (o IME confirma por aqui). O valor e
            // UTF-16: pares substitutos formam um codepoint.
            const unit: u16 = @truncate(wparam);
            const entry_idx = backend.findEntryByHwnd(hwnd) orelse return 0;
            const entry = &backend.entries.items[entry_idx];
            const slot = entry.slot;

            if (utf16ToCodepoint(unit, &entry.pending_high_surrogate)) |cp| {
                events.dispatch(queue, state, .{ .text_input = .{
                    .window = pending.reg.idOf(slot),
                    .codepoint = cp,
                } });
            }
            return 0;
        },
        api.WM_MOUSEMOVE => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                const pos = mousePos(lparam);
                events.dispatch(queue, state, .{
                    .pointer_move = .{ .window = pending.reg.idOf(slot), .x = pos[0], .y = pos[1] },
                });
            }
            return 0;
        },
        api.WM_LBUTTONDOWN, api.WM_RBUTTONDOWN, api.WM_MBUTTONDOWN => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                const pos = mousePos(lparam);
                events.dispatch(queue, state, .{
                    .pointer_button = .{
                        .window = pending.reg.idOf(slot),
                        .button = switch (msg) {
                            api.WM_LBUTTONDOWN => .left,
                            api.WM_RBUTTONDOWN => .right,
                            else => .middle,
                        },
                        .pressed = true,
                        .x = pos[0],
                        .y = pos[1],
                        .modifiers = currentMods(),
                    },
                });
            }
            return 0;
        },
        api.WM_LBUTTONUP, api.WM_RBUTTONUP, api.WM_MBUTTONUP => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                const pos = mousePos(lparam);
                events.dispatch(queue, state, .{
                    .pointer_button = .{
                        .window = pending.reg.idOf(slot),
                        .button = switch (msg) {
                            api.WM_LBUTTONUP => .left,
                            api.WM_RBUTTONUP => .right,
                            else => .middle,
                        },
                        .pressed = false,
                        .x = pos[0],
                        .y = pos[1],
                        .modifiers = currentMods(),
                    },
                });
            }
            return 0;
        },
        api.WM_XBUTTONDOWN, api.WM_XBUTTONUP => {
            const which: u16 = @truncate(wparam >> 16);
            const button: ?types.MouseButton = switch (which) {
                api.XBUTTON1 => .back,
                api.XBUTTON2 => .forward,
                else => null,
            };
            if (button) |b| {
                if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                    const pos = mousePos(lparam);
                    events.dispatch(queue, state, .{
                        .pointer_button = .{
                            .window = pending.reg.idOf(slot),
                            .button = b,
                            .pressed = msg == api.WM_XBUTTONDOWN,
                            .x = pos[0],
                            .y = pos[1],
                            .modifiers = currentMods(),
                        },
                    });
                }
            }
            return 0;
        },
        api.WM_MOUSEWHEEL, api.WM_MOUSEHWHEEL => {
            if (backend.slotOfNative(pending.reg, hwnd)) |slot| {
                const raw: u16 = @truncate(wparam >> 16);
                const delta: i16 = @bitCast(raw);
                const lines: f32 = @as(f32, @floatFromInt(delta)) /
                    @as(f32, @floatFromInt(api.WHEEL_DELTA));
                // Nota: coordenadas de tela->cliente disponiveis via
                // ScreenToClient; ScrollEvent nao as carrega nesta fase.
                const scroll: events.ScrollEvent = if (msg == api.WM_MOUSEWHEEL)
                    .{ .window = pending.reg.idOf(slot), .dx = 0, .dy = lines }
                else
                    .{ .window = pending.reg.idOf(slot), .dx = lines, .dy = 0 };
                events.dispatch(queue, state, .{ .scroll = scroll });
            }
            return 0;
        },
        else => {},
    }
    return api.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn mouseCoord(lparam: api.LPARAM, comptime word: u1) i32 {
    const bits: usize = @bitCast(lparam);
    const shifted = if (word == 0) bits else bits >> 16;
    const as_u16: u16 = @truncate(shifted);
    const as_i16: i16 = @bitCast(as_u16);
    return as_i16;
}

fn mousePos(lparam: api.LPARAM) struct { i32, i32 } {
    return .{ mouseCoord(lparam, 0), mouseCoord(lparam, 1) };
}

/// Bit 0x8000 de GetKeyState: tecla pressionada no momento em que a
/// mensagem atual foi retirada da fila. Puro e testavel sem SO.
fn stateIsDown(state: i16) bool {
    return (@as(u16, @bitCast(state)) & 0x8000) != 0;
}

fn keyDown(vk: api.WPARAM) bool {
    return stateIsDown(api.GetKeyState(@intCast(vk)));
}

/// Modificadores derivados do estado autoritativo do SO, nao de
/// rastreamento incremental: evita modificador preso quando o key_up
/// nao chega (perda de foco) e o caso de Shift/Ctrl/Alt esquerdo e
/// direito pressionados ao mesmo tempo (soltar um nao zera o outro).
/// `Key` continua sem distinguir lados (VK generico).
fn currentMods() types.Modifiers {
    return .{
        .shift = keyDown(api.VK_SHIFT),
        .control = keyDown(api.VK_CONTROL),
        .alt = keyDown(api.VK_MENU),
        .super = keyDown(api.VK_LWIN) or keyDown(api.VK_RWIN),
    };
}

/// Recurso IDC_* de cada variante logica (winuser.h). Pura e testavel.
pub fn cursorResource(cursor: types.Cursor) usize {
    return switch (cursor) {
        .default => api.IDC_ARROW,
        .text => api.IDC_IBEAM,
        .crosshair => api.IDC_CROSS,
        .hand => api.IDC_HAND,
        .resize_horizontal => api.IDC_SIZEWE,
        .resize_vertical => api.IDC_SIZENS,
        .resize_all => api.IDC_SIZEALL,
        .not_allowed => api.IDC_NO,
        .wait => api.IDC_WAIT,
    };
}

/// Carrega o cursor do sistema. Recursos IDC_* sao compartilhados pelo
/// sistema: nao devem ser liberados. Fallback para a seta se o recurso
/// pedido nao existir.
fn loadCursor(cursor: types.Cursor) api.HCURSOR {
    const handle = api.LoadCursorW(null, cursorResource(cursor));
    if (handle != null) return handle;
    return api.LoadCursorW(null, api.IDC_ARROW);
}

pub fn fromVk(vk: u16) types.Key {
    if (vk >= 0x41 and vk <= 0x5a) {
        return switch (vk) {
            0x41 => .a,
            0x42 => .b,
            0x43 => .c,
            0x44 => .d,
            0x45 => .e,
            0x46 => .f,
            0x47 => .g,
            0x48 => .h,
            0x49 => .i,
            0x4a => .j,
            0x4b => .k,
            0x4c => .l,
            0x4d => .m,
            0x4e => .n,
            0x4f => .o,
            0x50 => .p,
            0x51 => .q,
            0x52 => .r,
            0x53 => .s,
            0x54 => .t,
            0x55 => .u,
            0x56 => .v,
            0x57 => .w,
            0x58 => .x,
            0x59 => .y,
            0x5a => .z,
            else => .unknown,
        };
    }
    if (vk >= 0x30 and vk <= 0x39) {
        return switch (vk) {
            0x30 => .n0,
            0x31 => .n1,
            0x32 => .n2,
            0x33 => .n3,
            0x34 => .n4,
            0x35 => .n5,
            0x36 => .n6,
            0x37 => .n7,
            0x38 => .n8,
            0x39 => .n9,
            else => .unknown,
        };
    }
    // Numpad 0-9 mapeados para n0-n9 nesta fase (documentado).
    if (vk >= 0x60 and vk <= 0x69) {
        return switch (vk) {
            0x60 => .n0,
            0x61 => .n1,
            0x62 => .n2,
            0x63 => .n3,
            0x64 => .n4,
            0x65 => .n5,
            0x66 => .n6,
            0x67 => .n7,
            0x68 => .n8,
            0x69 => .n9,
            else => .unknown,
        };
    }
    if (vk >= 0x70 and vk <= 0x7b) {
        return switch (vk - 0x70) {
            0 => .f1,
            1 => .f2,
            2 => .f3,
            3 => .f4,
            4 => .f5,
            5 => .f6,
            6 => .f7,
            7 => .f8,
            8 => .f9,
            9 => .f10,
            10 => .f11,
            11 => .f12,
            else => .unknown,
        };
    }
    return switch (vk) {
        api.VK_ESCAPE => .escape,
        api.VK_TAB => .tab,
        api.VK_RETURN => .enter,
        api.VK_BACK => .backspace,
        api.VK_DELETE => .delete,
        api.VK_INSERT => .insert,
        api.VK_HOME => .home,
        api.VK_END => .end,
        api.VK_PRIOR => .page_up,
        api.VK_NEXT => .page_down,
        api.VK_LEFT => .left,
        api.VK_UP => .up,
        api.VK_RIGHT => .right,
        api.VK_DOWN => .down,
        // Modificadores: WM_KEYDOWN entrega o VK generico, sem lado.
        // Esquerda/direita so via scancode (lparam bits 16-23); o X11
        // distingue. Documentado em docs/BACKENDS.md.
        api.VK_SHIFT, api.VK_LSHIFT, api.VK_RSHIFT => .left_shift,
        api.VK_CONTROL, api.VK_LCONTROL, api.VK_RCONTROL => .left_control,
        api.VK_MENU, api.VK_LMENU, api.VK_RMENU => .left_alt,
        api.VK_LWIN, api.VK_RWIN => .left_super,
        api.VK_CAPITAL => .caps_lock,
        api.VK_NUMLOCK => .num_lock,
        api.VK_SPACE => .space,
        api.VK_OEM_MINUS => .minus,
        api.VK_OEM_PLUS => .equal,
        api.VK_OEM_4 => .bracket_left,
        api.VK_OEM_6 => .bracket_right,
        api.VK_OEM_1 => .semicolon,
        api.VK_OEM_7 => .apostrophe,
        api.VK_OEM_3 => .grave,
        api.VK_OEM_5 => .backslash,
        api.VK_OEM_COMMA => .comma,
        api.VK_OEM_PERIOD => .period,
        api.VK_OEM_2 => .slash,
        else => .unknown,
    };
}

// Os testes abaixo compilam em qualquer SO (nao tocam na API nativa).
test "cursor resources map to win32 IDC constants" {
    try std.testing.expectEqual(api.IDC_ARROW, cursorResource(.default));
    try std.testing.expectEqual(api.IDC_IBEAM, cursorResource(.text));
    try std.testing.expectEqual(api.IDC_CROSS, cursorResource(.crosshair));
    try std.testing.expectEqual(api.IDC_HAND, cursorResource(.hand));
    try std.testing.expectEqual(api.IDC_SIZEWE, cursorResource(.resize_horizontal));
    try std.testing.expectEqual(api.IDC_SIZENS, cursorResource(.resize_vertical));
    try std.testing.expectEqual(api.IDC_SIZEALL, cursorResource(.resize_all));
    try std.testing.expectEqual(api.IDC_NO, cursorResource(.not_allowed));
    try std.testing.expectEqual(api.IDC_WAIT, cursorResource(.wait));
}

test "vk mapping covers basics" {
    try std.testing.expectEqual(types.Key.escape, fromVk(0x1B));
    try std.testing.expectEqual(types.Key.a, fromVk(0x41));
    try std.testing.expectEqual(types.Key.n0, fromVk(0x30));
    try std.testing.expectEqual(types.Key.f5, fromVk(0x74));
    try std.testing.expectEqual(types.Key.left, fromVk(0x25));
    try std.testing.expectEqual(types.Key.unknown, fromVk(0xFF));
}

test "getkeystate high bit decodes as pressed" {
    try std.testing.expect(!stateIsDown(0));
    // Bit de toggle (CapsLock/NumLock) sem o bit de pressionada.
    try std.testing.expect(!stateIsDown(1));
    try std.testing.expect(stateIsDown(@bitCast(@as(u16, 0x8000))));
    try std.testing.expect(stateIsDown(@bitCast(@as(u16, 0x8001))));
}

test "win32 struct layouts match win64" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(api.WNDCLASSEXW));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(api.MSG));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(api.MONITORINFO));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(api.MONITORINFO, "rcMonitor"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(api.MONITORINFO, "rcWork"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(api.MONITORINFO, "dwFlags"));
}

test "utf16 units combine into unicode codepoints" {
    var pending: u16 = 0;
    // BMP: direto.
    try std.testing.expectEqual(@as(?u32, 'a'), utf16ToCodepoint('a', &pending));
    try std.testing.expectEqual(@as(?u32, 0x00E9), utf16ToCodepoint(0x00E9, &pending)); // e-acento
    try std.testing.expectEqual(@as(?u32, 0x4E2D), utf16ToCodepoint(0x4E2D, &pending)); // CJK

    // Par substituto: a parte alta nao produz texto sozinha.
    try std.testing.expectEqual(@as(?u32, null), utf16ToCodepoint(0xD83D, &pending));
    try std.testing.expectEqual(@as(u16, 0xD83D), pending);
    try std.testing.expectEqual(@as(?u32, 0x1F600), utf16ToCodepoint(0xDE00, &pending)); // emoji
    try std.testing.expectEqual(@as(u16, 0), pending);

    // Parte baixa sem par: sem texto.
    try std.testing.expectEqual(@as(?u32, null), utf16ToCodepoint(0xDE00, &pending));
}

test "win32 display mode id packs and unpacks" {
    const encoded = packModeId(1920, 1080, 7);
    const decoded = unpackModeId(encoded) orelse return error.TestExpectedModeId;
    try std.testing.expectEqual(@as(u32, 1920), decoded.width);
    try std.testing.expectEqual(@as(u32, 1080), decoded.height);
    try std.testing.expectEqual(@as(u32, 7), decoded.index);

    // Largura/altura zero nao formam um id valido.
    try std.testing.expect(unpackModeId(0) == null);
    try std.testing.expect(unpackModeId(packModeId(0, 1080, 1)) == null);
    try std.testing.expect(unpackModeId(packModeId(1920, 0, 1)) == null);
}

test "class names are unique per counter" {
    var a: [max_class_name:0]u16 = undefined;
    var b: [max_class_name:0]u16 = undefined;
    formatClassName(0, &a);
    formatClassName(4294967295, &b);
    const expected_a = "ZigwayWindow#0";
    for (expected_a, 0..) |c, i| try std.testing.expectEqual(@as(u16, c), a[i]);
    try std.testing.expectEqual(@as(u16, 0), a[expected_a.len]);
    const expected_b = "ZigwayWindow#4294967295";
    for (expected_b, 0..) |c, i| try std.testing.expectEqual(@as(u16, c), b[i]);
    try std.testing.expectEqual(@as(u16, 0), b[expected_b.len]);
    try std.testing.expect(!std.mem.eql(u16, a[0..expected_a.len], b[0..expected_a.len]));
}
