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
};

const Pending = struct {
    reg: *registry.Registry,
    queue: ?*events.EventQueue,
    state: ?*input.InputState,
};

const class_name: [13:0]u16 = .{
    'Z', 'i', 'g', 'w', 'a', 'y', 'W', 'i', 'n', 'd', 'o', 'w', 0,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    instance: api.HINSTANCE,
    class_atom: api.ATOM,
    entries: std.ArrayList(Entry) = .empty,
    pending: ?Pending = null,
    mods: types.Modifiers = .{},

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const instance = api.GetModuleHandleW(null);
        const cls = api.WNDCLASSEXW{
            .cbSize = @sizeOf(api.WNDCLASSEXW),
            .style = api.CS_HREDRAW | api.CS_VREDRAW | api.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = api.LoadCursorW(null, api.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = @ptrCast(&class_name),
            .hIconSm = null,
        };
        const atom = api.RegisterClassExW(&cls);
        if (atom == 0) return error.ConnectionFailed;
        return .{
            .allocator = allocator,
            .instance = instance,
            .class_atom = atom,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.entries.deinit(self.allocator);
        _ = api.UnregisterClassW(@ptrCast(&class_name), self.instance);
    }

    fn findEntry(self: *const Backend, slot: u32) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.slot == slot) return i;
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
            @ptrCast(&class_name),
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

        if (cfg.visible) _ = api.ShowWindow(hwnd, api.SW_SHOW);
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
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
                events.dispatch(queue, state, .{
                    .close = .{ .window = wid },
                });
                if (backend.findEntry(slot)) |i| {
                    _ = backend.entries.swapRemove(i);
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
            trackModifier(backend, vk, pressed);
            const wid: ?types.WindowId = if (backend.slotOfNative(pending.reg, hwnd)) |slot|
                pending.reg.idOf(slot)
            else
                null;
            const bits: usize = @bitCast(lparam);
            const kev: events.KeyEvent = .{
                .window = wid,
                .key = key,
                .modifiers = backend.mods,
                .repeat = pressed and ((bits >> 30) & 1) == 1,
            };
            if (pressed) {
                events.dispatch(queue, state, .{ .key_down = kev });
            } else {
                events.dispatch(queue, state, .{ .key_up = kev });
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
                        .modifiers = modsFromWparam(backend, wparam),
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
                        .modifiers = modsFromWparam(backend, wparam),
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
                            .modifiers = modsFromWparam(backend, wparam),
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

fn modsFromWparam(backend: *Backend, wparam: api.WPARAM) types.Modifiers {
    var mods = backend.mods;
    mods.shift = (wparam & api.MK_SHIFT) != 0;
    mods.control = (wparam & api.MK_CONTROL) != 0;
    return mods;
}

fn trackModifier(backend: *Backend, vk: u16, pressed: bool) void {
    switch (vk) {
        api.VK_SHIFT, api.VK_LSHIFT, api.VK_RSHIFT => backend.mods.shift = pressed,
        api.VK_CONTROL, api.VK_LCONTROL, api.VK_RCONTROL => backend.mods.control = pressed,
        api.VK_MENU, api.VK_LMENU, api.VK_RMENU => backend.mods.alt = pressed,
        api.VK_LWIN, api.VK_RWIN => backend.mods.super = pressed,
        else => {},
    }
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
test "vk mapping covers basics" {
    try std.testing.expectEqual(types.Key.escape, fromVk(0x1B));
    try std.testing.expectEqual(types.Key.a, fromVk(0x41));
    try std.testing.expectEqual(types.Key.n0, fromVk(0x30));
    try std.testing.expectEqual(types.Key.f5, fromVk(0x74));
    try std.testing.expectEqual(types.Key.left, fromVk(0x25));
    try std.testing.expectEqual(types.Key.unknown, fromVk(0xFF));
}

test "win32 struct layouts match win64" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(api.WNDCLASSEXW));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(api.MSG));
}
