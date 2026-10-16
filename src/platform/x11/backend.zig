// Zigway X11: backend sobre Xlib (declaracoes manuais em api.zig).
//
// Threading: afinidade com a thread criadora (Xlib nao e thread-safe por
// padrao para a mesma conexao). Repeticao automatica de tecla (auto-repeat)
// e reportada como key_down sucessivos (sem flag repeat); deteccao fina e
// limitacao conhecida desta fase.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");

const Entry = struct {
    slot: u32,
    win: api.Window,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *api.Display,
    root: api.Window,
    wm_delete: api.Atom,
    wm_protocols: api.Atom,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const display = api.XOpenDisplay(null) orelse return error.NoDisplay;
        errdefer _ = api.XCloseDisplay(display);
        const root = api.XDefaultRootWindow(display);
        const wm_delete = api.XInternAtom(display, "WM_DELETE_WINDOW", 0);
        if (wm_delete == 0) return error.ConnectionFailed;
        const wm_protocols = api.XInternAtom(display, "WM_PROTOCOLS", 0);
        if (wm_protocols == 0) return error.ConnectionFailed;
        return .{
            .allocator = allocator,
            .display = display,
            .root = root,
            .wm_delete = wm_delete,
            .wm_protocols = wm_protocols,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.entries.deinit(self.allocator);
        _ = api.XCloseDisplay(self.display);
    }

    fn findEntry(self: *const Backend, slot: u32) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.slot == slot) return i;
        }
        return null;
    }

    fn slotOfNative(self: *const Backend, reg: *registry.Registry, win: api.Window) ?u32 {
        for (self.entries.items) |entry| {
            if (entry.win == win) {
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

    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        var title_buf: [1025:0]u8 = undefined;
        @memcpy(title_buf[0..cfg.title.len], cfg.title);
        title_buf[cfg.title.len] = 0;

        const win = api.XCreateSimpleWindow(
            self.display,
            self.root,
            0,
            0,
            cfg.width,
            cfg.height,
            0,
            0,
            0,
        );
        if (win == api.None) return error.WindowCreationFailed;
        errdefer _ = api.XDestroyWindow(self.display, win);

        _ = api.XSelectInput(self.display, win, api.input_mask);
        _ = api.XStoreName(self.display, win, @ptrCast(&title_buf));
        var protocols = [_]api.Atom{self.wm_delete};
        _ = api.XSetWMProtocols(self.display, win, &protocols, 1);
        if (cfg.visible) _ = api.XMapWindow(self.display, win);
        _ = api.XFlush(self.display);

        try self.entries.append(self.allocator, .{ .slot = slot, .win = win });
        reg.slots.items[slot].native_id = win;
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        // Remove o registro ANTES de destruir: o DestroyNotify resultante
        // nao encontra entrada e e ignorado (sem evento espurio).
        if (self.findEntry(slot)) |i| {
            const win = self.entries.items[i].win;
            _ = self.entries.swapRemove(i);
            _ = api.XDestroyWindow(self.display, win);
            _ = api.XFlush(self.display);
        }
        _ = reg;
    }

    pub fn setTitle(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        title: []const u8,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        var title_buf: [1025:0]u8 = undefined;
        @memcpy(title_buf[0..title.len], title);
        title_buf[title.len] = 0;
        _ = api.XStoreName(self.display, self.entries.items[entry_idx].win, @ptrCast(&title_buf));
        _ = api.XFlush(self.display);
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
        _ = api.XResizeWindow(self.display, self.entries.items[entry_idx].win, width, height);
        _ = api.XFlush(self.display);
        // Confirmacao chega via ConfigureNotify.
    }

    pub fn setVisible(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        visible: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const win = self.entries.items[entry_idx].win;
        if (visible) {
            _ = api.XMapWindow(self.display, win);
        } else {
            _ = api.XUnmapWindow(self.display, win);
        }
        _ = api.XFlush(self.display);
        reg.slots.items[slot].visible = visible;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        _ = api.XSetInputFocus(
            self.display,
            self.entries.items[entry_idx].win,
            api.RevertToParent,
            api.CurrentTime,
        );
        _ = api.XFlush(self.display);
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        while (api.XPending(self.display) > 0) {
            var ev: api.XEvent = undefined;
            _ = api.XNextEvent(self.display, &ev);
            self.translate(reg, queue, state, &ev);
        }
    }

    fn translate(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        ev: *const api.XEvent,
    ) void {
        switch (ev.type) {
            api.KeyPress, api.KeyRelease => {
                const pressed = ev.type == api.KeyPress;
                const wid = self.windowId(reg, ev.key.window);
                const sym = api.XLookupKeysym(&ev.key, 0);
                const key = fromKeysym(sym);
                const mods = fromState(ev.key.state);
                const kev: events.KeyEvent = .{
                    .window = wid,
                    .key = key,
                    .modifiers = mods,
                    .repeat = false,
                };
                if (pressed) {
                    events.dispatch(queue, state, .{ .key_down = kev });
                } else {
                    events.dispatch(queue, state, .{ .key_up = kev });
                }
            },
            api.ButtonPress, api.ButtonRelease => {
                const pressed = ev.type == api.ButtonPress;
                const wid = self.windowId(reg, ev.button.window);
                const mods = fromState(ev.button.state);
                const x: i32 = ev.button.x;
                const y: i32 = ev.button.y;
                // Roda: somente no press gera scroll.
                if (pressed) {
                    if (ev.button.button == api.Button4) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 0, .dy = 1 } });
                        return;
                    } else if (ev.button.button == api.Button5) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 0, .dy = -1 } });
                        return;
                    } else if (ev.button.button == api.Button6) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = -1, .dy = 0 } });
                        return;
                    } else if (ev.button.button == api.Button7) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 1, .dy = 0 } });
                        return;
                    }
                } else if (ev.button.button == api.Button4 or
                    ev.button.button == api.Button5 or
                    ev.button.button == api.Button6 or
                    ev.button.button == api.Button7)
                {
                    return;
                }
                const button: types.MouseButton = switch (ev.button.button) {
                    api.Button1 => .left,
                    api.Button2 => .middle,
                    api.Button3 => .right,
                    8 => .back,
                    9 => .forward,
                    else => return,
                };
                events.dispatch(queue, state, .{ .pointer_button = .{
                    .window = wid,
                    .button = button,
                    .pressed = pressed,
                    .x = x,
                    .y = y,
                    .modifiers = mods,
                } });
            },
            api.MotionNotify => {
                const wid = self.windowId(reg, ev.motion.window);
                events.dispatch(queue, state, .{ .pointer_move = .{
                    .window = wid,
                    .x = ev.motion.x,
                    .y = ev.motion.y,
                } });
            },
            api.ConfigureNotify => {
                const slot = self.slotOfNative(reg, ev.configure.window) orelse return;
                if (ev.configure.width < 0 or ev.configure.height < 0) return;
                const w: u32 = @intCast(ev.configure.width);
                const h: u32 = @intCast(ev.configure.height);
                const entry = &reg.slots.items[slot];
                if (entry.width != w or entry.height != h) {
                    entry.width = w;
                    entry.height = h;
                    events.dispatch(queue, state, .{ .resize = .{
                        .window = reg.idOf(slot),
                        .width = w,
                        .height = h,
                    } });
                }
            },
            api.FocusIn, api.FocusOut => {
                const slot = self.slotOfNative(reg, ev.focus.window) orelse return;
                const focused = ev.type == api.FocusIn;
                reg.slots.items[slot].focused = focused;
                const wid = reg.idOf(slot);
                events.dispatch(queue, state, .{ .focus = .{
                    .window = wid,
                    .focused = focused,
                } });
                // Perda de foco libera o que estava pressionado: o SO nao
                // entregara os key_up/button_up correspondentes.
                if (!focused) input.releaseAll(wid, queue, state);
            },
            api.ClientMessage => {
                if (ev.client.format != 32) return;
                if (ev.client.message_type != self.wm_protocols) return;
                const slot = self.slotOfNative(reg, ev.client.window) orelse return;
                // Protocolo WM_DELETE_WINDOW (atomos registrados no init).
                const proto: api.Atom = @bitCast(ev.client.data.l[0]);
                if (proto == self.wm_delete) {
                    events.dispatch(queue, state, .{ .close = .{ .window = reg.idOf(slot) } });
                }
            },
            api.DestroyNotify => {
                const slot = self.slotOfNative(reg, ev.destroy.window) orelse return;
                // Janela destruida pelo servidor: marca fechamento para que
                // o consumidor encerre e libere o slot.
                reg.slots.items[slot].should_close = true;
                const wid = reg.idOf(slot);
                events.dispatch(queue, state, .{ .close = .{ .window = wid } });
                // Remove a entrada: a nativa morreu; operacoes seguintes
                // retornam InvalidWindow em vez de atingir XID invalida
                // (BadWindow encerra o processo no handler padrao).
                if (self.findEntry(slot)) |i| {
                    _ = self.entries.swapRemove(i);
                }
            },
            api.MapNotify => {
                const slot = self.slotOfNative(reg, ev.map.window) orelse return;
                reg.slots.items[slot].visible = true;
            },
            api.UnmapNotify => {
                const slot = self.slotOfNative(reg, ev.unmap.window) orelse return;
                reg.slots.items[slot].visible = false;
            },
            else => {},
        }
    }

    fn windowId(
        self: *const Backend,
        reg: *registry.Registry,
        win: api.Window,
    ) ?types.WindowId {
        const slot = self.slotOfNative(reg, win) orelse return null;
        return reg.idOf(slot);
    }
};

pub fn fromState(state: c_uint) types.Modifiers {
    return .{
        .shift = (state & api.ShiftMask) != 0,
        .control = (state & api.ControlMask) != 0,
        .alt = (state & api.Mod1Mask) != 0,
        .super = (state & api.Mod4Mask) != 0,
    };
}

pub fn fromKeysym(sym: api.KeySym) types.Key {
    // Letras (minusculas e maiusculas -> mesma tecla logica).
    if ((sym >= 0x61 and sym <= 0x7a) or (sym >= 0x41 and sym <= 0x5a)) {
        const lower = sym | 0x20;
        return switch (lower) {
            0x61 => .a,
            0x62 => .b,
            0x63 => .c,
            0x64 => .d,
            0x65 => .e,
            0x66 => .f,
            0x67 => .g,
            0x68 => .h,
            0x69 => .i,
            0x6a => .j,
            0x6b => .k,
            0x6c => .l,
            0x6d => .m,
            0x6e => .n,
            0x6f => .o,
            0x70 => .p,
            0x71 => .q,
            0x72 => .r,
            0x73 => .s,
            0x74 => .t,
            0x75 => .u,
            0x76 => .v,
            0x77 => .w,
            0x78 => .x,
            0x79 => .y,
            0x7a => .z,
            else => .unknown,
        };
    }
    if (sym >= 0x30 and sym <= 0x39) {
        return switch (sym) {
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
    if (sym >= api.XK_F1 and sym < api.XK_F1 + 12) {
        return switch (sym - api.XK_F1) {
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
    return switch (sym) {
        api.XK_Escape => .escape,
        api.XK_Tab => .tab,
        api.XK_Return => .enter,
        api.XK_BackSpace => .backspace,
        api.XK_Delete => .delete,
        api.XK_Insert => .insert,
        api.XK_Home => .home,
        api.XK_End => .end,
        api.XK_Page_Up => .page_up,
        api.XK_Page_Down => .page_down,
        api.XK_Left => .left,
        api.XK_Up => .up,
        api.XK_Right => .right,
        api.XK_Down => .down,
        api.XK_Shift_L => .left_shift,
        api.XK_Shift_R => .right_shift,
        api.XK_Control_L => .left_control,
        api.XK_Control_R => .right_control,
        api.XK_Caps_Lock => .caps_lock,
        api.XK_Num_Lock => .num_lock,
        api.XK_Alt_L => .left_alt,
        api.XK_Alt_R => .right_alt,
        api.XK_Super_L => .left_super,
        api.XK_Super_R => .right_super,
        0x20 => .space,
        0x2d => .minus,
        0x3d => .equal,
        0x5b => .bracket_left,
        0x5d => .bracket_right,
        0x3b => .semicolon,
        0x27 => .apostrophe,
        0x60 => .grave,
        0x5c => .backslash,
        0x2c => .comma,
        0x2e => .period,
        0x2f => .slash,
        else => .unknown,
    };
}

test "keysym mapping covers basics" {
    try std.testing.expectEqual(types.Key.escape, fromKeysym(api.XK_Escape));
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x61));
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x41));
    try std.testing.expectEqual(types.Key.z, fromKeysym(0x7a));
    try std.testing.expectEqual(types.Key.n5, fromKeysym(0x35));
    try std.testing.expectEqual(types.Key.f1, fromKeysym(api.XK_F1));
    try std.testing.expectEqual(types.Key.f12, fromKeysym(api.XK_F1 + 11));
    try std.testing.expectEqual(types.Key.left, fromKeysym(api.XK_Left));
    try std.testing.expectEqual(types.Key.left_super, fromKeysym(api.XK_Super_L));
    try std.testing.expectEqual(types.Key.space, fromKeysym(0x20));
    try std.testing.expectEqual(types.Key.unknown, fromKeysym(0x1234));
}

test "state mask maps modifiers" {
    const mods = fromState(api.ShiftMask | api.ControlMask | api.Mod1Mask | api.Mod4Mask);
    try std.testing.expect(mods.shift and mods.control and mods.alt and mods.super);
    const none = fromState(0);
    try std.testing.expect(!none.shift and !none.control and !none.alt and !none.super);
}

test "xevent union matches C long pad" {
    // Xlib define `long pad[24]`: 192 bytes onde C long tem 8 bytes
    // (LP64 Unix), 96 onde tem 4 (Windows LLP64; o backend X11 nunca
    // executa la, mas os tipos compilam em qualquer alvo).
    const expected: usize = if (builtin.os.tag == .windows) 96 else 192;
    try std.testing.expectEqual(expected, @sizeOf(api.XEvent));
}
