// Teste live Wayland: conecta no compositor nativo (nao XWayland) e
// confere os outputs (monitores) e as capacidades do seat.
//
// Pula graciosamente (sem falhar) quando nao ha compositor Wayland
// disponivel (sem WAYLAND_DISPLAY / socket) ou quando a
// libwayland-client nao esta instalada.
//
// Executar com: zig build test-wayland

const std = @import("std");
const zigway = @import("zigway");

test "live wayland: connects to the compositor and lists outputs" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .wayland }) catch |err| {
        if (err == error.NoDisplay or err == error.UnsupportedBackend or
            err == error.ConnectionFailed or err == error.NotImplemented)
        {
            std.debug.print("\n[wl-live] compositor indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    try std.testing.expectEqual(zigway.ActiveBackend.wayland, plat.backendKind());

    const displays = try plat.displays(std.testing.allocator);
    defer std.testing.allocator.free(displays);

    // Um compositor Wayland expõe ao menos um output.
    try std.testing.expect(displays.len >= 1);
    for (displays) |info| {
        try std.testing.expect(info.width > 0);
        try std.testing.expect(info.height > 0);
        try std.testing.expect(info.id.isValid());
        std.debug.print("\n[wl-live] output {d}: {d}x{d} em ({d},{d})\n", .{
            info.id.raw,
            info.width,
            info.height,
            info.x,
            info.y,
        });
    }

    // O seat e opcional, mas quando presente tem ao menos uma
    // capacidade.
    if (plat.seatCapabilities()) |seat| {
        try std.testing.expect(seat.pointer or seat.keyboard or seat.touch);
    }

    // O despacho nao pode quebrar (roundtrip de eventos).
    plat.pollEvents();
    while (plat.nextEvent()) |_| {}
}
