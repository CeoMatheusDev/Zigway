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
