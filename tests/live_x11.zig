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

/// XKeyEvent (Xlib.h) para eventos sinteticos. XEvent e uma uniao de 24
/// longs (192 bytes em LP64); o buffer abaixo replica o tamanho total para
/// que XSendEvent copie a quantidade correta de bytes.
const XKeyEvent = extern struct {
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
    keycode: c_uint,
    same_screen: c_int,
};

const XEventBuf = extern struct {
    key: XKeyEvent,
    pad: [96]u8,
};

const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const KeyPressMask: c_long = 1;
const KeyReleaseMask: c_long = 2;

/// Envia um KeyPress/KeyRelease sintetico direto para `window` (sem
/// depender de foco/XTEST) e sincroniza o servidor.
fn sendKey(
    display: *anyopaque,
    window: c_ulong,
    root: c_ulong,
    keycode: u8,
    pressed: bool,
) void {
    var ev: XEventBuf = std.mem.zeroes(XEventBuf);
    ev.key = .{
        .type = if (pressed) KeyPress else KeyRelease,
        .serial = 0,
        .send_event = 1,
        .display = display,
        .window = window,
        .root = root,
        .subwindow = 0,
        .time = 0,
        .x = 0,
        .y = 0,
        .x_root = 0,
        .y_root = 0,
        .state = 0,
        .keycode = keycode,
        .same_screen = 1,
    };
    const mask: c_long = if (pressed) KeyPressMask else KeyReleaseMask;
    _ = XSendEvent(display, window, 0, mask, @ptrCast(&ev));
    _ = XSync(display, 0);
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
    const expected: zigway.Key = @fromBackingInt(@intCast(@as(u16, @intCast((sym | 0x20) - 0x61 + 1))));

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
