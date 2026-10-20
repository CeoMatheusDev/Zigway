// Teste live X11: abre display real, cria/destroi janela, drena eventos.
// Pula graciosamente (sem falhar) quando nao ha display.
// Executar com: zig build test-x11

const std = @import("std");
const zigway = @import("zigway");

const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

const XErrorHandler = *const fn (display: ?*anyopaque, event: *anyopaque) callconv(.c) c_int;
extern "X11" fn XSetErrorHandler(handler: XErrorHandler) XErrorHandler;

/// Contador de erros de protocolo durante o teste de cursores. O handler
/// da Xlib nao recebe contexto do usuario, por isso o estado e de arquivo.
var cursor_protocol_errors: usize = 0;

fn countCursorProtocolError(display: ?*anyopaque, event: *anyopaque) callconv(.c) c_int {
    _ = display;
    _ = event;
    cursor_protocol_errors += 1;
    return 0;
}

fn sleepMs(ms: u64) void {
    var req = Timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = nanosleep(&req, null);
}

test "live x11: open display, create window, poll, destroy" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        // Sem display, backend indisponivel ou SO sem X11: pula sem falhar.
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    try std.testing.expectEqual(zigway.ActiveBackend.x11, plat.backendKind());

    var window = try plat.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "zigway live test",
    });
    defer window.deinit();

    // Drena eventos iniciais (MapNotify etc.); nao exige interacao.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
    }

    try std.testing.expect(!window.shouldClose());
    try std.testing.expectEqual(@as(u32, 320), window.size().width);

    try window.setTitle("zigway live test 2");
    try window.setSize(400, 300);
    // A confirmacao chega via ConfigureNotify (assincrona via WM);
    // drena com folga de tempo real.
    var saw_resize = false;
    var waited: u32 = 0;
    while (waited < 3000 and !saw_resize) : (waited += 50) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            if (ev == .resize) saw_resize = true;
        }
        if (!saw_resize) sleepMs(50);
    }
    try std.testing.expect(saw_resize);
    try std.testing.expectEqual(@as(u32, 400), window.size().width);
}

// Acesso direto a Xlib apenas para os testes live abaixo (erro de
// protocolo e destruicao externa).
extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*anyopaque;
extern "X11" fn XDestroyWindow(display: *anyopaque, window: c_ulong) c_int;
extern "X11" fn XSync(display: *anyopaque, discard: c_int) c_int;
extern "X11" fn XCloseDisplay(display: *anyopaque) c_int;
extern "X11" fn XDefaultRootWindow(display: *anyopaque) c_ulong;
extern "X11" fn XQueryTree(
    display: *anyopaque,
    window: c_ulong,
    root_return: *c_ulong,
    parent_return: *c_ulong,
    children_return: *?[*]c_ulong,
    nchildren_return: *c_uint,
) c_int;
extern "X11" fn XFetchName(display: *anyopaque, window: c_ulong, name_return: *?[*:0]u8) c_int;
extern "X11" fn XSendEvent(
    display: *anyopaque,
    window: c_ulong,
    propagate: c_int,
    event_mask: c_long,
    event: *anyopaque,
) c_int;
extern "X11" fn XKeysymToKeycode(display: *anyopaque, keysym: c_ulong) u8;
extern "X11" fn XKeycodeToKeysym(display: *anyopaque, keycode: u8, index: c_int) c_ulong;

/// XKeyEvent/XButtonEvent/XMotionEvent (Xlib.h) tem o mesmo layout: os
/// tres terminam em um campo de 4 bytes (keycode, button, is_hint) na
/// mesma posicao. XEvent e uma uniao de 24 longs (192 bytes em LP64); o
/// buffer replica o tamanho total para que XSendEvent copie os bytes
/// corretos.
const XDeviceEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*anyopaque,
    window: c_ulong,
    root: c_ulong,
    subwindow: c_ulong,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    detail: c_uint, // keycode (Key*) ou button (Button*)
    same_screen: c_int,
};

const XEventBuf = extern struct {
    ev: XDeviceEvent,
    pad: [96]u8,
};

const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;

const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;

// Modificadores no campo `state` (X.h).
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3; // Alt
const Mod4Mask: c_uint = 1 << 6; // Super

/// Envia um evento sintetico direto para `window` (sem depender de
/// foco/XTEST) e sincroniza o servidor.
fn sendDeviceEvent(
    display: *anyopaque,
    window: c_ulong,
    root: c_ulong,
    event_type: c_int,
    event_mask: c_long,
    detail: c_uint,
    state: c_uint,
    x: c_int,
    y: c_int,
) void {
    var buf: XEventBuf = std.mem.zeroes(XEventBuf);
    buf.ev = .{
        .type = event_type,
        .serial = 0,
        .send_event = 1,
        .display = display,
        .window = window,
        .root = root,
        .subwindow = 0,
        .time = 0,
        .x = x,
        .y = y,
        .x_root = x,
        .y_root = y,
        .state = state,
        .detail = detail,
        .same_screen = 1,
    };
    _ = XSendEvent(display, window, 0, event_mask, @ptrCast(&buf));
    _ = XSync(display, 0);
}

fn sendKey(
    display: *anyopaque,
    window: c_ulong,
    root: c_ulong,
    keycode: u8,
    pressed: bool,
) void {
    sendDeviceEvent(
        display,
        window,
        root,
        if (pressed) KeyPress else KeyRelease,
        if (pressed) KeyPressMask else KeyReleaseMask,
        keycode,
        0,
        0,
        0,
    );
}

extern "X11" fn XGetWMProtocols(
    display: *anyopaque,
    window: c_ulong,
    protocols_return: *?[*]c_ulong,
    count_return: *c_int,
) c_int;
extern "X11" fn XFree(data: ?*anyopaque) c_int;

/// Localiza recursivamente (WM pode reparentar) a JANELA CLIENTE pelo
/// titulo, exigindo tambem WM_PROTOCOLS — o frame criado por um WM pode
/// herdar o nome, mas nao o protocolo registrado pelo Zigway.
fn findClientWindowByTitle(
    display: *anyopaque,
    window: c_ulong,
    title: []const u8,
    depth: u8,
) ?c_ulong {
    if (depth > 5) return null;
    var root_ret: c_ulong = 0;
    var parent_ret: c_ulong = 0;
    var children: ?[*]c_ulong = null;
    var count: c_uint = 0;
    if (XQueryTree(display, window, &root_ret, &parent_ret, &children, &count) == 0) return null;
    defer if (children) |c| {
        _ = XFree(@as(?*anyopaque, @ptrCast(c)));
    };

    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const child = children.?[i];
        var name: ?[*:0]u8 = null;
        if (XFetchName(display, child, &name) != 0 and name != null) {
            const matches = std.mem.eql(u8, std.mem.span(name.?), title);
            _ = XFree(@as(?*anyopaque, @ptrCast(name)));
            if (matches and hasWmProtocols(display, child)) return child;
        }
        if (findClientWindowByTitle(display, child, title, depth + 1)) |found| return found;
    }
    return null;
}

fn hasWmProtocols(display: *anyopaque, window: c_ulong) bool {
    var protocols: ?[*]c_ulong = null;
    var count: c_int = 0;
    const has = XGetWMProtocols(display, window, &protocols, &count) != 0;
    if (protocols) |p| _ = XFree(@as(?*anyopaque, @ptrCast(p)));
    return has;
}

/// Drena eventos ate encontrar o key_down/key_up pedido (descarta os
/// demais). Retorna null se nada chegar dentro da janela de espera.
fn pollKey(plat: *zigway.Platform, pressed: bool) ?zigway.KeyEvent {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .key_down => |e| if (pressed) return e,
                .key_up => |e| if (!pressed) return e,
                else => {},
            }
        }
        sleepMs(5);
    }
    return null;
}

fn pollPointerMove(plat: *zigway.Platform) ?zigway.PointerMoveEvent {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .pointer_move => |e| return e,
                else => {},
            }
        }
        sleepMs(5);
    }
    return null;
}

fn pollPointerButton(plat: *zigway.Platform) ?zigway.PointerButtonEvent {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .pointer_button => |e| return e,
                else => {},
            }
        }
        sleepMs(5);
    }
    return null;
}

fn pollScroll(plat: *zigway.Platform) ?zigway.ScrollEvent {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .scroll => |e| return e,
                else => {},
            }
        }
        sleepMs(5);
    }
    return null;
}

/// Espera a janela cliente aparecer (WM pode reparentar) e devolve o
/// XID nativo; null se nao aparecer no prazo (ambiente exotico -> pula).
fn waitForNativeWindow(display: *anyopaque, root: c_ulong, title: []const u8) ?c_ulong {
    var tries: usize = 0;
    while (tries < 400) : (tries += 1) {
        _ = XSync(display, 0);
        if (findClientWindowByTitle(display, root, title, 0)) |window| return window;
        sleepMs(5);
    }
    return null;
}

test "live x11: external destroy emits close once and invalidates operations" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const title = "zigway-live-external-destroy";
    var window = try plat.createWindow(.{ .width = 320, .height = 240, .title = title });
    defer window.deinit();
    const id = window.windowId();

    const display = XOpenDisplay(null) orelse return;
    defer _ = XCloseDisplay(display);
    const root = XDefaultRootWindow(display);

    // Localiza a nativa (mapeamento/reparent podem demorar um pouco).
    var target: ?c_ulong = null;
    var tries: usize = 0;
    while (tries < 400 and target == null) : (tries += 1) {
        _ = XSync(display, 0);
        target = findClientWindowByTitle(display, root, title, 0);
        if (target == null) sleepMs(5);
    }
    const native = target orelse {
        // Ambiente sem WM_PROTOCOLS visivel (ou WM exotico): nao falha o
        // teste por isso — mas avisa.
        std.debug.print("\n[x11-live] janela nativa nao encontrada; pulando.\n", .{});
        return;
    };

    // Destruicao externa (como o servidor/WM faria).
    _ = XDestroyWindow(display, native);
    _ = XSync(display, 0);

    var closes: usize = 0;
    tries = 0;
    while (tries < 600 and closes == 0) : (tries += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            if (ev == .close and ev.close.window.eql(id)) closes += 1;
        }
        if (closes == 0) sleepMs(5);
    }

    // Exatamente um `close`; fechamento marcado; entrada nativa removida
    // (operacoes passam a falhar); slot ainda ocupado ate o consumidor
    // destruir.
    try std.testing.expectEqual(@as(usize, 1), closes);
    try std.testing.expect(plat.windowShouldClose(id));
    try std.testing.expect(plat.isWindowAlive(id));
    try std.testing.expectError(error.InvalidWindow, plat.setWindowTitle(id, "x"));

    // Destroy do consumidor libera o slot e nao gera evento espurio.
    try plat.destroyWindow(id);
    plat.pollEvents();
    while (plat.nextEvent()) |ev| {
        if (ev == .close and ev.close.window.eql(id)) {
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(!plat.isWindowAlive(id));
}

test "live x11: multiple windows are independent" {
    // Valida independencia entre janelas nativas simultaneas: ids
    // distintos, resize isolado, destroy nao afeta a outra e poda de
    // eventos da janela destruida.
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    var w1 = try plat.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "zigway-live-multi-1",
    });
    defer w1.deinit();
    var w2 = try plat.createWindow(.{
        .width = 480,
        .height = 360,
        .title = "zigway-live-multi-2",
    });
    defer w2.deinit();

    const id1 = w1.windowId();
    const id2 = w2.windowId();
    try std.testing.expect(!id1.eql(id2));

    // Drena eventos iniciais (MapNotify etc.).
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
    }

    try std.testing.expect(!w1.shouldClose());
    try std.testing.expect(!w2.shouldClose());
    try std.testing.expectEqual(@as(u32, 320), w1.size().width);
    try std.testing.expectEqual(@as(u32, 480), w2.size().width);

    // Resize em w1 nao afeta w2.
    try w1.setSize(400, 300);
    var saw_resize = false;
    var waited: u32 = 0;
    while (waited < 3000 and !saw_resize) : (waited += 50) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            if (ev == .resize and ev.resize.window.eql(id1)) saw_resize = true;
        }
        if (!saw_resize) sleepMs(50);
    }
    try std.testing.expect(saw_resize);
    try std.testing.expectEqual(@as(u32, 400), w1.size().width);
    try std.testing.expectEqual(@as(u32, 480), w2.size().width);

    // Destruir w1 nao afeta w2.
    try plat.destroyWindow(id1);
    w1.id = zigway.WindowId.invalid;
    try std.testing.expect(!w1.isValid());
    try std.testing.expect(w2.isValid());
    try std.testing.expect(!plat.isWindowAlive(id1));
    try std.testing.expect(plat.isWindowAlive(id2));

    // Eventos pendentes de w1 sao podados; w2 segue funcional.
    plat.pollEvents();
    while (plat.nextEvent()) |ev| {
        if (ev.window()) |wid| {
            if (wid.eql(id1)) return error.UnexpectedEvent;
        }
    }

    try w2.setTitle("zigway-live-multi-2b");
    try std.testing.expectEqual(@as(u32, 480), w2.size().width);
}

test "live x11: visibility toggle via Map/Unmap" {
    // Valida setVisible end-to-end: XUnmapWindow/XMapWindow geram
    // UnmapNotify/MapNotify, que atualizam slot.visible.
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    var w = try plat.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "zigway-live-visibility",
    });
    defer w.deinit();

    // Drena eventos iniciais (MapNotify etc.).
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
    }

    try std.testing.expect(plat.isWindowVisible(w.windowId()));

    // Unmap.
    try w.setVisible(false);
    var saw_unmap = false;
    var waited: u32 = 0;
    while (waited < 3000 and !saw_unmap) : (waited += 50) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        if (!plat.isWindowVisible(w.windowId())) saw_unmap = true;
        if (!saw_unmap) sleepMs(50);
    }
    try std.testing.expect(saw_unmap);
    try std.testing.expect(!plat.isWindowVisible(w.windowId()));

    // Map.
    try w.setVisible(true);
    var saw_map = false;
    waited = 0;
    while (waited < 3000 and !saw_map) : (waited += 50) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        if (plat.isWindowVisible(w.windowId())) saw_map = true;
        if (!saw_map) sleepMs(50);
    }
    try std.testing.expect(saw_map);
    try std.testing.expect(plat.isWindowVisible(w.windowId()));
}

test "live x11: focus in/out updates state" {
    // Valida FocusIn/FocusOut end-to-end: XSetInputFocus gera FocusIn,
    // que atualiza slot.focused. Em ambiente sem WM, o foco pode não ser
    // concedido; o teste não falha por isso (degrada graciosamente).
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    var w = try plat.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "zigway-live-focus",
    });
    defer w.deinit();

    // Drena eventos iniciais.
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
    }

    // Tenta dar foco à janela.
    try w.focus();
    var saw_focus = false;
    var waited: u32 = 0;
    while (waited < 3000 and !saw_focus) : (waited += 50) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            if (ev == .focus and ev.focus.focused) saw_focus = true;
        }
        if (!saw_focus) sleepMs(50);
    }

    // Em ambiente sem WM, o foco pode não ser concedido; não falha o teste.
    if (saw_focus) {
        try std.testing.expect(plat.isWindowFocused(w.windowId()));
    }
}

test "live x11: auto-repeat is flagged on repeated KeyPress" {
    // Valida a deteccao de repeat de ponta a ponta: dois KeyPress da mesma
    // tecla sem KeyRelease intermediario (semantica de detectable
    // autorepeat). O primeiro e key_down normal; o segundo, repeat=true.
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const title = "zigway-live-repeat";
    var window = try plat.createWindow(.{ .width = 320, .height = 240, .title = title });
    defer window.deinit();

    // XEvent e uma uniao de 24 longs; o buffer precisa do tamanho total.
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(XEventBuf));

    const display = XOpenDisplay(null) orelse return;
    defer _ = XCloseDisplay(display);
    const root = XDefaultRootWindow(display);

    var target: ?c_ulong = null;
    var tries: usize = 0;
    while (tries < 400 and target == null) : (tries += 1) {
        _ = XSync(display, 0);
        target = findClientWindowByTitle(display, root, title, 0);
        if (target == null) sleepMs(5);
    }
    const native = target orelse {
        std.debug.print("\n[x11-live] janela nativa nao encontrada; pulando.\n", .{});
        return;
    };

    // Tecla cujo keysym em shift level 0 e uma letra ASCII (mapeada).
    const keycode = XKeysymToKeycode(display, 0x61); // XK_a
    if (keycode == 0) return;
    const sym = XKeycodeToKeysym(display, keycode, 0);
    const is_letter = (sym >= 0x61 and sym <= 0x7a) or (sym >= 0x41 and sym <= 0x5a);
    if (!is_letter) {
        std.debug.print("\n[x11-live] layout sem letra ASCII no keycode; pulando.\n", .{});
        return;
    }
    // Key.a = 1, ..., Key.z = 26 (ordinais densos, cobertos por teste).
    const expected: zigway.Key = @fromBackingInt(@intCast((sym | 0x20) - 0x61 + 1));

    // Primeiro press: key_down normal.
    sendKey(display, native, root, keycode, true);
    const first = pollKey(&plat, true) orelse return error.MissingKeyEvent;
    try std.testing.expectEqual(expected, first.key);
    try std.testing.expect(!first.repeat);
    try std.testing.expect(first.window.?.eql(window.windowId()));
    try std.testing.expect(plat.inputState().isKeyDown(expected));

    // Segundo press sem release: repeticao automatica.
    sendKey(display, native, root, keycode, true);
    const second = pollKey(&plat, true) orelse return error.MissingKeyEvent;
    try std.testing.expectEqual(expected, second.key);
    try std.testing.expect(second.repeat);
    try std.testing.expect(plat.inputState().isKeyDown(expected));

    // Release fisico: key_up normal e estado limpo.
    sendKey(display, native, root, keycode, false);
    const release = pollKey(&plat, false) orelse return error.MissingKeyEvent;
    try std.testing.expectEqual(expected, release.key);
    try std.testing.expect(!release.repeat);
    try std.testing.expect(!plat.inputState().isKeyDown(expected));
}

test "live x11: pointer move, buttons and wheel update input state" {
    // Cobre o caminho de mouse de ponta a ponta com eventos sinteticos:
    // MotionNotify, ButtonPress/Release e roda (botoes 4-7).
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const title = "zigway-live-mouse";
    var window = try plat.createWindow(.{ .width = 320, .height = 240, .title = title });
    defer window.deinit();
    const id = window.windowId();

    const display = XOpenDisplay(null) orelse return;
    defer _ = XCloseDisplay(display);
    const root = XDefaultRootWindow(display);
    const native = waitForNativeWindow(display, root, title) orelse {
        std.debug.print("\n[x11-live] janela nativa nao encontrada; pulando.\n", .{});
        return;
    };

    // Foco e melhor esforco; verificacoes de estado global sao gated por
    // isWindowFocused (FocusOut legitimo chama releaseAll).
    window.focus() catch {};

    // Movimento: evento e estado de ponteiro (coordenadas da janela).
    sendDeviceEvent(display, native, root, MotionNotify, PointerMotionMask, 0, 0, 12, 34);
    const move = pollPointerMove(&plat) orelse return error.MissingPointerMove;
    try std.testing.expectEqual(@as(i32, 12), move.x);
    try std.testing.expectEqual(@as(i32, 34), move.y);
    try std.testing.expect(move.window.?.eql(id));
    try std.testing.expectEqual(@as(i32, 12), plat.inputState().pointer_x);
    try std.testing.expectEqual(@as(i32, 34), plat.inputState().pointer_y);

    // Botao esquerdo com Shift no state: modificador vem do servidor.
    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 1, ShiftMask, 12, 34);
    const press = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.left, press.button);
    try std.testing.expect(press.pressed);
    try std.testing.expect(press.modifiers.shift);
    try std.testing.expect(press.window.?.eql(id));
    if (plat.isWindowFocused(id)) {
        try std.testing.expect(plat.inputState().isButtonDown(.left));
        try std.testing.expect(plat.inputState().modifiers.shift);
    }

    sendDeviceEvent(display, native, root, ButtonRelease, ButtonReleaseMask, 1, 0, 12, 34);
    const release = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.left, release.button);
    try std.testing.expect(!release.pressed);
    try std.testing.expect(!release.modifiers.shift);
    try std.testing.expect(!plat.inputState().isButtonDown(.left));
    try std.testing.expect(!plat.inputState().modifiers.shift);

    // Botao direito (button 3) e medio (button 2): mesmo caminho.
    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 3, 0, 12, 34);
    const right_press = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.right, right_press.button);
    try std.testing.expect(right_press.pressed);
    if (plat.isWindowFocused(id)) {
        try std.testing.expect(plat.inputState().isButtonDown(.right));
    }

    sendDeviceEvent(display, native, root, ButtonRelease, ButtonReleaseMask, 3, 0, 12, 34);
    const right_release = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.right, right_release.button);
    try std.testing.expect(!right_release.pressed);
    try std.testing.expect(!plat.inputState().isButtonDown(.right));

    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 2, 0, 12, 34);
    const middle_press = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.middle, middle_press.button);
    try std.testing.expect(middle_press.pressed);
    if (plat.isWindowFocused(id)) {
        try std.testing.expect(plat.inputState().isButtonDown(.middle));
    }

    sendDeviceEvent(display, native, root, ButtonRelease, ButtonReleaseMask, 2, 0, 12, 34);
    const middle_release = pollPointerButton(&plat) orelse return error.MissingPointerButton;
    try std.testing.expectEqual(zigway.MouseButton.middle, middle_release.button);
    try std.testing.expect(!middle_release.pressed);
    try std.testing.expect(!plat.inputState().isButtonDown(.middle));

    // Roda vertical (4=cima, 5=baixo) e horizontal (6=esq, 7=dir).
    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 4, 0, 12, 34);
    const up = pollScroll(&plat) orelse return error.MissingScroll;
    try std.testing.expectEqual(@as(f32, 0), up.dx);
    try std.testing.expectEqual(@as(f32, 1), up.dy);
    try std.testing.expect(up.window.?.eql(id));

    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 5, 0, 12, 34);
    const down = pollScroll(&plat) orelse return error.MissingScroll;
    try std.testing.expectEqual(@as(f32, 0), down.dx);
    try std.testing.expectEqual(@as(f32, -1), down.dy);

    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 6, 0, 12, 34);
    const left = pollScroll(&plat) orelse return error.MissingScroll;
    try std.testing.expectEqual(@as(f32, -1), left.dx);

    sendDeviceEvent(display, native, root, ButtonPress, ButtonPressMask, 7, 0, 12, 34);
    const right = pollScroll(&plat) orelse return error.MissingScroll;
    try std.testing.expectEqual(@as(f32, 1), right.dx);
    try std.testing.expectEqual(@as(f32, 0), right.dy);
}

test "live x11: modifiers come from the server event mask" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const title = "zigway-live-mods";
    var window = try plat.createWindow(.{ .width = 320, .height = 240, .title = title });
    defer window.deinit();
    const id = window.windowId();

    const display = XOpenDisplay(null) orelse return;
    defer _ = XCloseDisplay(display);
    const root = XDefaultRootWindow(display);
    const native = waitForNativeWindow(display, root, title) orelse {
        std.debug.print("\n[x11-live] janela nativa nao encontrada; pulando.\n", .{});
        return;
    };

    const keycode = XKeysymToKeycode(display, 0x61); // XK_a
    if (keycode == 0) return;
    const sym = XKeycodeToKeysym(display, keycode, 0);
    const is_letter = (sym >= 0x61 and sym <= 0x7a) or (sym >= 0x41 and sym <= 0x5a);
    if (!is_letter) {
        std.debug.print("\n[x11-live] layout sem letra ASCII no keycode; pulando.\n", .{});
        return;
    }
    const expected: zigway.Key = @fromBackingInt(@intCast((sym | 0x20) - 0x61 + 1));

    // Foco e melhor esforco (WM pode negar); as verificacoes de estado
    // global sao gated por isWindowFocused para nao correr com FocusOut.
    window.focus() catch {};

    // Press com Shift+Ctrl+Alt+Super no state do evento.
    const all = ShiftMask | ControlMask | Mod1Mask | Mod4Mask;
    sendDeviceEvent(display, native, root, KeyPress, KeyPressMask, keycode, all, 0, 0);
    const press = pollKey(&plat, true) orelse return error.MissingKeyEvent;
    try std.testing.expectEqual(expected, press.key);
    try std.testing.expect(press.modifiers.shift);
    try std.testing.expect(press.modifiers.control);
    try std.testing.expect(press.modifiers.alt);
    try std.testing.expect(press.modifiers.super);
    if (plat.isWindowFocused(id)) {
        try std.testing.expect(plat.inputState().modifiers.shift);
        try std.testing.expect(plat.inputState().modifiers.control);
        try std.testing.expect(plat.inputState().modifiers.alt);
        try std.testing.expect(plat.inputState().modifiers.super);
    }

    // Release com apenas Alt retido: o estado reflete o mask do evento.
    sendDeviceEvent(display, native, root, KeyRelease, KeyReleaseMask, keycode, Mod1Mask, 0, 0);
    const release = pollKey(&plat, false) orelse return error.MissingKeyEvent;
    try std.testing.expectEqual(expected, release.key);
    try std.testing.expect(!release.modifiers.shift);
    try std.testing.expect(!release.modifiers.control);
    try std.testing.expect(release.modifiers.alt);
    try std.testing.expect(!release.modifiers.super);
    // O estado global so e verificado com a janela focada: um FocusOut
    // legitimo chama releaseAll e limpa modificadores/teclas.
    if (plat.isWindowFocused(id)) {
        try std.testing.expect(!plat.inputState().isKeyDown(expected));
        try std.testing.expect(plat.inputState().modifiers.alt);
    }
}

test "live x11: all system cursors are created and applied without errors" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    var window = try plat.createWindow(.{
        .width = 200,
        .height = 120,
        .title = "zigway cursor live test",
    });
    defer window.deinit();

    // Conta erros de protocolo (BadCursor/BadWindow) durante as chamadas.
    // O handler do backend e restaurado no fim do escopo.
    const previous = XSetErrorHandler(countCursorProtocolError);
    defer _ = XSetErrorHandler(previous);
    cursor_protocol_errors = 0;

    // XCreateFontCursor retornando 0 vira CursorCreationFailed: cobre
    // disponibilidade da cursor font e mapeamento de todas as formas.
    for (std.meta.tags(zigway.Cursor)) |cursor| {
        try window.setCursor(cursor);
    }
    // Reaplica variantes para exercitar o cache por backend.
    try window.setCursor(.text);
    try window.setCursor(.default);

    // XPending processa erros assincronos da conexao do backend.
    plat.pollEvents();
    while (plat.nextEvent()) |_| {}

    try std.testing.expectEqual(@as(usize, 0), cursor_protocol_errors);
    try std.testing.expect(!window.shouldClose());
}

test "live x11: protocol error does not abort the process" {
    // `Platform.init(.x11)` instala o handler de erro da Xlib. Sem ele, um
    // erro de protocolo (BadWindow) encerra o processo no handler padrao —
    // o que faria este binario de teste abortar. Se este teste termina, o
    // processo sobreviveu.
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-live] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const display = XOpenDisplay(null) orelse return;
    defer _ = XCloseDisplay(display);

    // XID inexistente -> BadWindow assincrono, processado no XSync.
    _ = XDestroyWindow(display, 0x7ffffffe);
    _ = XSync(display, 0);

    try std.testing.expectEqual(zigway.ActiveBackend.x11, plat.backendKind());
}
