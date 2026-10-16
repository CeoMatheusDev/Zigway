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
