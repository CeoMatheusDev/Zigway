// Teste live X11 destrutivo: troca o modo de video do display atual.
//
// Executar com: zig build test-x11-modes
//
// ATENCAO: este teste altera a resolucao do display. O modo original e
// restaurado ao final (inclusive em caso de falha). Pula graciosamente
// quando nao ha display ou quando o display nao expoe modos (RandR 1.5+
// ausente, monitor sem CRTC ativo ou sem modo alternativo).

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

/// Modo corrente do display (null quando nenhum modo esta marcado).
fn currentMode(plat: *zigway.Platform, id: zigway.DisplayId) !?zigway.DisplayMode {
    const modes = try plat.displayModes(std.testing.allocator, id);
    defer std.testing.allocator.free(modes);
    for (modes) |mode| {
        if (mode.current) return mode;
    }
    return null;
}

/// Aguarda o modo esperado virar o corrente (evento RandR).
fn waitForMode(
    plat: *zigway.Platform,
    id: zigway.DisplayId,
    expected: zigway.DisplayModeId,
) !bool {
    var attempts: u32 = 0;
    while (attempts < 150) : (attempts += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        if (try currentMode(plat, id)) |now| {
            if (now.id.eql(expected)) return true;
        }
        sleepMs(20);
    }
    return false;
}

test "live x11: switching display mode applies and restores the mode" {
    var plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .x11 }) catch |err| {
        if (err == error.NoDisplay or err == error.ConnectionFailed or
            err == error.UnsupportedBackend or err == error.NotImplemented)
        {
            std.debug.print("\n[x11-modes] backend indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer plat.deinit();

    const displays = try plat.displays(std.testing.allocator);
    defer std.testing.allocator.free(displays);

    // Escolhe o primeiro display com um modo alternativo que nao seja maior
    // que o modo atual (troca para cima exigiria expandir a tela).
    var target_display: ?zigway.DisplayInfo = null;
    var target_mode: ?zigway.DisplayMode = null;
    var original_mode: ?zigway.DisplayMode = null;
    for (displays) |info| {
        const modes = try plat.displayModes(std.testing.allocator, info.id);
        defer std.testing.allocator.free(modes);
        if (modes.len == 0) continue;

        var current: ?zigway.DisplayMode = null;
        for (modes) |mode| {
            if (mode.current) current = mode;
        }
        const current_mode = current orelse continue;

        var best: ?zigway.DisplayMode = null;
        for (modes) |mode| {
            if (mode.current) continue;
            if (mode.width > current_mode.width or mode.height > current_mode.height) continue;
            const area = @as(u64, mode.width) * mode.height;
            if (best == null or area > @as(u64, best.?.width) * best.?.height) best = mode;
        }
        if (best) |mode| {
            target_display = info;
            target_mode = mode;
            original_mode = current;
            break;
        }
    }

    const display = target_display orelse {
        std.debug.print(
            "\n[x11-modes] nenhum display com modo alternativo; pulando.\n",
            .{},
        );
        return;
    };
    const mode = target_mode.?;
    const original = original_mode.?;

    // Restaura o modo original mesmo se o teste falhar no meio.
    defer {
        plat.setDisplayMode(display.id, original.id) catch |err| {
            std.debug.print("\n[x11-modes] falha ao restaurar modo: {t}\n", .{err});
        };
    }

    std.debug.print(
        "\n[x11-modes] display {d}: {d}x{d} -> {d}x{d} (mhz {d})\n",
        .{ display.id.raw, original.width, original.height, mode.width, mode.height, mode.refresh_mhz },
    );

    try plat.setDisplayMode(display.id, mode.id);
    try std.testing.expect(try waitForMode(&plat, display.id, mode.id));

    try plat.setDisplayMode(display.id, original.id);
    try std.testing.expect(try waitForMode(&plat, display.id, original.id));
}
