// Zigway X11: backend sobre Xlib (declaracoes manuais em api.zig).
//
// Threading: afinidade com a thread criadora (Xlib nao e thread-safe por
// padrao para a mesma conexao). Auto-repeat: o init habilita detectable
// autorepeat (XKB), de modo que repeticoes chegam como KeyPress sem
// KeyRelease intermediario e sao marcadas com `repeat=true`.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const xrandr = @import("xrandr.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");

const Entry = struct {
    slot: u32,
    win: api.Window,
};

/// Handler de erro de protocolo X. Por padrao a Xlib encerra o processo em
/// qualquer erro; a corrida real e: uma requisicao assincrona (ex.
/// `XStoreName`) e enviada antes de processarmos o `DestroyNotify` de uma
/// janela que o servidor acabou de destruir — a remocao de entrada fecha o
/// caminho normal, mas a janela de tempo existe. Retornar 0 mantem o
/// processo (o host) vivo. E global ao processo (a Xlib tem um unico
/// handler), sem estado proprio, e permanece instalado apos `deinit`.
fn xErrorHandler(display: ?*api.Display, event: *api.XErrorEvent) callconv(.c) c_int {
    _ = display;
    _ = event;
    return 0;
}

/// Verifica se `atom` esta na propriedade `property` (formato ATOM) da
/// janela. Usado para detectar `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`
/// sem depender de um WM especifico.
fn propertyHasAtom(
    display: *api.Display,
    target: api.Window,
    property: api.Atom,
    atom: api.Atom,
) bool {
    if (property == 0 or atom == 0) return false;
    var actual_type: api.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var raw: ?[*]u8 = null;
    const status = api.XGetWindowProperty(
        display,
        target,
        property,
        0,
        1024,
        0,
        api.XA_ATOM,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &raw,
    );
    defer {
        if (raw) |ptr| _ = api.XFree(@ptrCast(ptr));
    }
    if (status != 0) return false;
    if (actual_type != api.XA_ATOM or actual_format != 32) return false;
    // Formato 32 da Xlib e devolvido como array de `long`, nao de int.
    const values: [*]c_ulong = @ptrCast(@alignCast(raw orelse return false));
    var i: usize = 0;
    while (i < @as(usize, @intCast(nitems))) : (i += 1) {
        if (values[i] == atom) return true;
    }
    return false;
}

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *api.Display,
    root: api.Window,
    wm_delete: api.Atom,
    wm_protocols: api.Atom,
    /// `_NET_MOVERESIZE_WINDOW` (EWMH): posicionamento absoluto com
    /// StaticGravity quando suportado pelo WM.
    net_moveresize_window: api.Atom,
    /// O WM anunciou `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`.
    net_moveresize_supported: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    /// Cache de cursores por variante, criado sob demanda e liberado no
    /// deinit. Handles sao globais ao backend (compartilhados por janelas).
    cursors: [types.Cursor.count]api.Cursor = @splat(0),
    /// Slot da janela com grab de ponteiro (exclusivo por conexao), se
    /// houver. O servidor libera o grab quando a janela fica nao-visivel
    /// ou e destruida; os handlers de evento limpam o estado nesses casos.
    captured: ?u32 = null,
    /// libXrandr carregada em runtime (opcional). Mantida viva ate depois
    /// de XCloseDisplay: a biblioteca registra extensoes na Xlib.
    xrandr: ?xrandr.Lib = null,
    /// RandR 1.5+ disponivel, com `XRRGetMonitors` utilizavel.
    xrandr_monitors: bool = false,
    /// event_base RandR quando screen/crtc/output notifications foram
    /// selecionados no root; null sem libXrandr/simbolos.
    xrandr_event_base: ?c_int = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const display = api.XOpenDisplay(null) orelse return error.NoDisplay;
        errdefer _ = api.XCloseDisplay(display);
        // Nao deixa o handler padrao da Xlib encerrar o processo em um erro
        // de protocolo recuperavel (ver xErrorHandler).
        _ = api.XSetErrorHandler(xErrorHandler);
        // Auto-repeat: "detectable autorepeat" faz o servidor enviar apenas
        // KeyPress repetidos (sem KeyRelease no meio), o que permite marcar
        // `repeat` sem apagar o estado da tecla. Servidor sem suporte
        // devolve false em `supported`; nesse caso repeat fica false
        // (fallback igual ao comportamento anterior).
        var xkb_supported: api.XBool = 0;
        _ = api.XkbSetDetectableAutoRepeat(display, 1, &xkb_supported);
        const root = api.XDefaultRootWindow(display);
        const wm_delete = api.XInternAtom(display, "WM_DELETE_WINDOW", 0);
        if (wm_delete == 0) return error.ConnectionFailed;
        const wm_protocols = api.XInternAtom(display, "WM_PROTOCOLS", 0);
        if (wm_protocols == 0) return error.ConnectionFailed;
        const net_moveresize_window = api.XInternAtom(display, "_NET_MOVERESIZE_WINDOW", 0);
        const net_supported = api.XInternAtom(display, "_NET_SUPPORTED", 0);
        const net_moveresize_supported = propertyHasAtom(
            display,
            root,
            net_supported,
            net_moveresize_window,
        );
        // Opcional e sem dependencia de link. Carregado por ultimo: nao ha
        // mais operacoes faliveis no init, entao o errdefer do display
        // continua correto em qualquer falha anterior.
        const xrandr_lib = xrandr.Lib.load();
        var xrandr_monitors = false;
        var xrandr_event_base: ?c_int = null;
        if (xrandr_lib) |*lib| {
            xrandr_monitors = lib.supportsMonitors(display);
            xrandr_event_base = lib.enableEvents(display, root);
        }
        return .{
            .allocator = allocator,
            .display = display,
            .root = root,
            .wm_delete = wm_delete,
            .wm_protocols = wm_protocols,
            .net_moveresize_window = net_moveresize_window,
            .net_moveresize_supported = net_moveresize_supported,
            .xrandr = xrandr_lib,
            .xrandr_monitors = xrandr_monitors,
            .xrandr_event_base = xrandr_event_base,
        };
    }

    pub fn deinit(self: *Backend) void {
        if (self.captured != null) _ = api.XUngrabPointer(self.display, api.CurrentTime);
        for (self.cursors) |handle| {
            if (handle != 0) _ = api.XFreeCursor(self.display, handle);
        }
        self.entries.deinit(self.allocator);
        _ = api.XCloseDisplay(self.display);
        // So depois do display: dlclose antes de XCloseDisplay deixa
        // callbacks da extensao apontando para codigo descarregado.
        if (self.xrandr) |*lib| lib.deinit();
    }

    /// Snapshot dos monitores. Com RandR 1.5+ usa `XRRGetMonitors`; caso
    /// contrario cai para as X screens (cada uma com origem 0,0). O
    /// chamador libera a slice com o mesmo alocador.
    pub fn displays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        if (self.xrandr_monitors) {
            if (self.xrandr) |*lib| {
                if (try lib.monitors(self.display, self.root, allocator)) |list| {
                    return list;
                }
            }
        }
        return self.screenDisplays(allocator);
    }

    fn screenDisplays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        const count = api.XScreenCount(self.display);
        if (count <= 0) return allocator.alloc(types.DisplayInfo, 0);
        const n: usize = @intCast(count);
        const list = try allocator.alloc(types.DisplayInfo, n);
        errdefer allocator.free(list);
        const default_screen = api.XDefaultScreen(self.display);
        for (list, 0..) |*info, i| {
            const screen: c_int = @intCast(i);
            const width = api.XDisplayWidth(self.display, screen);
            const height = api.XDisplayHeight(self.display, screen);
            info.* = .{
                .id = .{ .raw = @intCast(i) },
                // X screens tem espacos de coordenadas independentes;
                // nao ha posicao global combinada.
                .x = 0,
                .y = 0,
                .width = std.math.cast(u32, width) orelse 0,
                .height = std.math.cast(u32, height) orelse 0,
                .primary = screen == default_screen,
            };
        }
        return list;
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
        // Solta o grab antes de destruir a janela (o servidor tambem
        // liberaria automaticamente, mas o estado local ficaria obsoleto).
        self.releasePointer(reg, slot);
        // Remove o registro ANTES de destruir: o DestroyNotify resultante
        // nao encontra entrada e e ignorado (sem evento espurio).
        if (self.findEntry(slot)) |i| {
            const win = self.entries.items[i].win;
            _ = self.entries.swapRemove(i);
            _ = api.XDestroyWindow(self.display, win);
            _ = api.XFlush(self.display);
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

    /// Move a origem da area de cliente para (x, y) em coordenadas de
    /// tela. Se o WM anunciar `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`,
    /// usa EWMH + StaticGravity; caso contrario usa `XMoveWindow`
    /// (melhor esforco). Confirmacao via ConfigureNotify.
    pub fn setPosition(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        x: i32,
        y: i32,
    ) !void {
        _ = reg;
        _ = queue;
        _ = state;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const win = self.entries.items[entry_idx].win;

        if (self.net_moveresize_supported and self.net_moveresize_window != 0) {
            // data.l[0]: gravidade (StaticGravity) | flags (x,y) << 8 |
            // source (aplicacao) << 12. Ver EWMH 4.2.
            const flags: c_long = api.StaticGravity | (0x03 << 8) | (1 << 12);
            var event = api.XEvent{ .client = .{
                .type = api.ClientMessage,
                .serial = 0,
                .send_event = 1,
                .display = self.display,
                .window = win,
                .message_type = self.net_moveresize_window,
                .format = 32,
                .data = .{ .l = .{ flags, @intCast(x), @intCast(y), 0, 0 } },
            } };
            if (api.XSendEvent(
                self.display,
                self.root,
                0,
                api.SubstructureRedirectMask | api.SubstructureNotifyMask,
                &event,
            ) != 0) {
                _ = api.XFlush(self.display);
                return;
            }
        }

        if (api.XMoveWindow(self.display, win, x, y) == 0) {
            return error.WindowMoveFailed;
        }
        _ = api.XFlush(self.display);
    }

    /// Posicao atual da origem da area de cliente, consultada na Xlib
    /// (funciona com janelas reparented pelo WM).
    pub fn position(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) types.WindowPosition {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return .{ .x = 0, .y = 0 };
        return self.clientPosition(self.entries.items[entry_idx].win) orelse .{ .x = 0, .y = 0 };
    }

    fn clientPosition(self: *const Backend, win: api.Window) ?types.WindowPosition {
        var x: c_int = 0;
        var y: c_int = 0;
        var child: api.Window = 0;
        if (api.XTranslateCoordinates(
            self.display,
            win,
            self.root,
            0,
            0,
            &x,
            &y,
            &child,
        ) == 0) return null;
        return .{ .x = x, .y = y };
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

    pub fn setCursor(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cursor: types.Cursor,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const handle = try self.cursorHandle(cursor);
        if (api.XDefineCursor(self.display, self.entries.items[entry_idx].win, handle) == 0) {
            return error.CursorCreationFailed;
        }
        _ = api.XFlush(self.display);
    }

    /// Cria (uma vez) e devolve o handle nativo da variante. Falha de
    /// criacao nao e cacheada: a proxima chamada tenta de novo.
    fn cursorHandle(self: *Backend, cursor: types.Cursor) !api.Cursor {
        const idx: usize = @backingInt(cursor);
        if (self.cursors[idx] != 0) return self.cursors[idx];
        const handle = api.XCreateFontCursor(self.display, cursorShape(cursor));
        if (handle == 0) return error.CursorCreationFailed;
        self.cursors[idx] = handle;
        return handle;
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        if (self.captured == slot) return;
        // Captura exclusiva por conexao: transferir exige soltar a atual.
        if (self.captured != null) {
            _ = api.XUngrabPointer(self.display, api.CurrentTime);
            self.captured = null;
        }
        const status = api.XGrabPointer(
            self.display,
            self.entries.items[entry_idx].win,
            api.True,
            @intCast(api.ButtonPressMask | api.ButtonReleaseMask | api.PointerMotionMask),
            api.GrabModeAsync,
            api.GrabModeAsync,
            api.None, // confine_to: nao confina o ponteiro
            api.None, // cursor: nao altera o cursor
            api.CurrentTime,
        );
        if (status != api.GrabSuccess) return error.PointerCaptureFailed;
        self.captured = slot;
        _ = api.XFlush(self.display);
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured != slot) return;
        _ = api.XUngrabPointer(self.display, api.CurrentTime);
        self.captured = null;
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
        ev: *api.XEvent,
    ) void {
        // RandR: evento base + 0 = RRScreenChangeNotify; + 1 = RRNotify
        // (CRTC/output). Ambos significam que o snapshot de displays pode
        // ter mudado; um aviso sem payload e suficiente.
        if (self.xrandr_event_base) |base| {
            if (ev.type == base) {
                if (self.xrandr) |*lib| lib.updateConfiguration(ev);
                events.dispatch(queue, state, .{ .display_change = .{} });
                return;
            }
            if (ev.type == base + 1) {
                events.dispatch(queue, state, .{ .display_change = .{} });
                return;
            }
        }
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
                    .repeat = pressed and isRepeat(state, key),
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
                if (self.clientPosition(ev.configure.window)) |pos| {
                    if (entry.x != pos.x or entry.y != pos.y) {
                        entry.x = pos.x;
                        entry.y = pos.y;
                        events.dispatch(queue, state, .{ .move = .{
                            .window = reg.idOf(slot),
                            .x = pos.x,
                            .y = pos.y,
                        } });
                    }
                }
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
                // O servidor libera o grab junto com a janela.
                if (self.captured == slot) self.captured = null;
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
                // XGrabPointer exige janela viewable: o servidor libera o
                // grab ao desmapear; o estado local acompanha.
                if (self.captured == slot) self.captured = null;
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

/// Auto-repeat: com detectable autorepeat ligado, o servidor omite o
/// KeyRelease entre repeticoes, entao um KeyPress de uma tecla mapeada que
/// ja esta pressionada e repeticao. `.unknown` agrupa teclas distintas nao
/// mapeadas e por isso nunca e tratado como repeticao (evita marcar uma
/// tecla diferente como repeat).
pub fn isRepeat(state: *const input.InputState, key: types.Key) bool {
    if (key == .unknown) return false;
    return state.isKeyDown(key);
}

/// Forma nativa (cursorfont.h) de cada variante logica. Pura e testavel
/// sem display. `.not_allowed` usa XC_X_cursor (o cursorfont nao tem uma
/// forma "proibido" dedicada).
pub fn cursorShape(cursor: types.Cursor) c_uint {
    return switch (cursor) {
        .default => api.XC_left_ptr,
        .text => api.XC_xterm,
        .crosshair => api.XC_crosshair,
        .hand => api.XC_hand2,
        .resize_horizontal => api.XC_sb_h_double_arrow,
        .resize_vertical => api.XC_sb_v_double_arrow,
        .resize_all => api.XC_fleur,
        .not_allowed => api.XC_X_cursor,
        .wait => api.XC_watch,
    };
}

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
    // Teclado numerico: mesmas teclas logicas do Win32. Com NumLock
    // ligado, XK_KP_0..9 -> n0..n9; desligado, o servidor entrega as
    // chaves de navegacao XK_KP_Home etc. `Key` nao distingue numpad da
    // linha superior (nem o Win32 distingue). Operadores (KP_Add,
    // KP_Multiply, ...) nao tem variante em `Key` e seguem `.unknown`,
    // como no Win32 (VK_ADD/VK_MULTIPLY tambem nao mapeados).
    if (sym >= api.XK_KP_0 and sym <= api.XK_KP_0 + 9) {
        return switch (sym - api.XK_KP_0) {
            0 => .n0,
            1 => .n1,
            2 => .n2,
            3 => .n3,
            4 => .n4,
            5 => .n5,
            6 => .n6,
            7 => .n7,
            8 => .n8,
            9 => .n9,
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
        api.XK_KP_Enter => .enter,
        api.XK_KP_Home => .home,
        api.XK_KP_Left => .left,
        api.XK_KP_Up => .up,
        api.XK_KP_Right => .right,
        api.XK_KP_Down => .down,
        api.XK_KP_Prior => .page_up,
        api.XK_KP_Next => .page_down,
        api.XK_KP_End => .end,
        api.XK_KP_Insert => .insert,
        api.XK_KP_Delete => .delete,
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

test "cursor shapes map to cursorfont constants" {
    try std.testing.expectEqual(api.XC_left_ptr, cursorShape(.default));
    try std.testing.expectEqual(api.XC_xterm, cursorShape(.text));
    try std.testing.expectEqual(api.XC_crosshair, cursorShape(.crosshair));
    try std.testing.expectEqual(api.XC_hand2, cursorShape(.hand));
    try std.testing.expectEqual(api.XC_sb_h_double_arrow, cursorShape(.resize_horizontal));
    try std.testing.expectEqual(api.XC_sb_v_double_arrow, cursorShape(.resize_vertical));
    try std.testing.expectEqual(api.XC_fleur, cursorShape(.resize_all));
    try std.testing.expectEqual(api.XC_X_cursor, cursorShape(.not_allowed));
    try std.testing.expectEqual(api.XC_watch, cursorShape(.wait));
}

test "numpad keysyms match win32 logical keys" {
    // Com NumLock: digitos.
    try std.testing.expectEqual(types.Key.n0, fromKeysym(api.XK_KP_0));
    try std.testing.expectEqual(types.Key.n5, fromKeysym(api.XK_KP_0 + 5));
    try std.testing.expectEqual(types.Key.n9, fromKeysym(api.XK_KP_0 + 9));
    try std.testing.expectEqual(types.Key.enter, fromKeysym(api.XK_KP_Enter));
    // Sem NumLock: navegacao (mesmo resultado do Win32 com NumLock off).
    try std.testing.expectEqual(types.Key.home, fromKeysym(api.XK_KP_Home));
    try std.testing.expectEqual(types.Key.left, fromKeysym(api.XK_KP_Left));
    try std.testing.expectEqual(types.Key.up, fromKeysym(api.XK_KP_Up));
    try std.testing.expectEqual(types.Key.right, fromKeysym(api.XK_KP_Right));
    try std.testing.expectEqual(types.Key.down, fromKeysym(api.XK_KP_Down));
    try std.testing.expectEqual(types.Key.page_up, fromKeysym(api.XK_KP_Prior));
    try std.testing.expectEqual(types.Key.page_down, fromKeysym(api.XK_KP_Next));
    try std.testing.expectEqual(types.Key.end, fromKeysym(api.XK_KP_End));
    try std.testing.expectEqual(types.Key.insert, fromKeysym(api.XK_KP_Insert));
    try std.testing.expectEqual(types.Key.delete, fromKeysym(api.XK_KP_Delete));
}

test "repeat detection flags a second key_down of a mapped key" {
    var state = input.InputState{};
    const id: types.WindowId = .{ .index = 0, .generation = 0 };

    try std.testing.expect(!isRepeat(&state, .a));
    state.apply(.{ .key_down = .{
        .window = id,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });
    // Mesma tecla pressionada: repeticao. Outra tecla: nao.
    try std.testing.expect(isRepeat(&state, .a));
    try std.testing.expect(!isRepeat(&state, .b));
    // `.unknown` agrupa teclas distintas; nunca vira repeticao.
    try std.testing.expect(!isRepeat(&state, .unknown));

    state.apply(.{ .key_up = .{
        .window = id,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });
    try std.testing.expect(!isRepeat(&state, .a));
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

test "xerror event layout matches LP64" {
    // XErrorEvent (Xlib.h): int + Display* + XID(long) + ulong + 3 uchar
    // -> 40 bytes em LP64. No Windows nao executa (X11 e Linux-only).
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(api.XErrorEvent));
    }
}

test "xerror handler swallows protocol errors" {
    // Deve retornar 0 (a Xlib segue) em vez de encerrar o processo.
    var ev = std.mem.zeroes(api.XErrorEvent);
    try std.testing.expectEqual(@as(c_int, 0), xErrorHandler(null, &ev));
}
