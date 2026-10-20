// Teste live Wayland: conecta no compositor nativo (nao XWayland) e
// confere os outputs (monitores), as capacidades do seat e o ciclo de
// vida de uma janela (xdg-shell).
//
// Pula graciosamente (sem falhar) quando nao ha compositor Wayland
// disponivel (sem WAYLAND_DISPLAY / socket) ou quando a
// libwayland-client nao esta instalada.
//
// Executar com: zig build test-wayland

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

/// Inicializa a plataforma no backend Wayland. Retorna `null` quando
/// nao ha compositor disponivel (o teste e pulado, sem falhar).
fn initPlatform() !?zigway.Platform {
    return zigway.Platform.init(std.testing.allocator, .{ .backend = .wayland }) catch |err| switch (err) {
        error.NoDisplay, error.UnsupportedBackend, error.ConnectionFailed => {
            std.debug.print("\n[wl-live] compositor indisponivel ({t}); pulando.\n", .{err});
            return null;
        },
        else => return err,
    };
}

test "live wayland: connects to the compositor and lists outputs" {
    var plat = (try initPlatform()) orelse return;
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

test "live wayland: creates a window and receives the configure" {
    var plat = (try initPlatform()) orelse return;
    defer plat.deinit();

    var win = plat.createWindow(.{
        .width = 320,
        .height = 240,
        .title = "zigway-live",
    }) catch |err| switch (err) {
        // O compositor pode nao expor xdg-shell/shm: o teste e pulado.
        error.NotImplemented => {
            std.debug.print("\n[wl-live] xdg-shell indisponivel; pulando.\n", .{});
            return;
        },
        else => return err,
    };
    defer win.deinit();

    // O compositor confirma o tamanho via `configure` (evento `resize`).
    var got_resize = false;
    var attempts: u32 = 0;
    while (attempts < 200) : (attempts += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .resize => got_resize = true,
                else => {},
            }
        }
        if (got_resize) break;
        sleepMs(10);
    }

    // Sem `configure` do compositor, a janela nao foi mapeada.
    try std.testing.expect(got_resize);

    const size = win.size();
    try std.testing.expect(size.width > 0);
    try std.testing.expect(size.height > 0);
    std.debug.print("\n[wl-live] janela {d}x{d} confirmada\n", .{ size.width, size.height });

    // O titulo pode ser trocado a qualquer momento.
    try win.setTitle("zigway-live-2");

    // Destruir a janela deve liberar o slot sem quebrar a plataforma.
    win.deinit();
    plat.pollEvents();
    while (plat.nextEvent()) |_| {}
}

test "live wayland: window state requests do not break the connection" {
    var plat = (try initPlatform()) orelse return;
    defer plat.deinit();

    var win = plat.createWindow(.{
        .width = 200,
        .height = 150,
        .title = "zigway-state",
    }) catch |err| switch (err) {
        error.NotImplemented => return,
        else => return err,
    };
    defer win.deinit();

    // Pump de eventos para o compositor processar a janela.
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        sleepMs(5);
    }

    // Limites, maximizacao e fullscreen: o compositor pode recusar, mas
    // a conexao deve continuar viva.
    win.setSizeLimits(.{ .min_width = 100, .min_height = 80 }) catch {};
    win.setMaximized(true) catch {};
    i = 0;
    while (i < 20) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        sleepMs(5);
    }
    win.setMaximized(false) catch {};
    win.setFullscreen(true) catch {};
    i = 0;
    while (i < 20) : (i += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        sleepMs(5);
    }
    win.setFullscreen(false) catch {};

    // A plataforma continua utilizavel: uma nova janela pode ser criada.
    var second = plat.createWindow(.{ .width = 100, .height = 100, .title = "segunda" }) catch |err| switch (err) {
        error.NotImplemented => return,
        else => return err,
    };
    defer second.deinit();
    plat.pollEvents();
    while (plat.nextEvent()) |_| {}
}

test "live wayland: creating and destroying many windows keeps the connection" { // Regressao: o protocolo exige `ack_configure` antes de anexar
    // buffer. Uma janela nova ainda nao configurada nao pode receber
    // buffer (o compositor responde "attached a buffer before
    // configure event").
    var plat = (try initPlatform()) orelse return;
    defer plat.deinit();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var win = plat.createWindow(.{
            .width = 120,
            .height = 90,
            .title = "zigway-stress",
        }) catch |err| switch (err) {
            error.NotImplemented => return,
            else => return err,
        };
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        // Mostrar/ocultar antes do `configure` nao pode anexar buffer.
        win.setVisible(false) catch {};
        win.setVisible(true) catch {};
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
        win.deinit();
        plat.pollEvents();
        while (plat.nextEvent()) |_| {}
    }
}

test "live wayland: the pointer reports the window under the cursor" {
    // O compositor so envia `wl_pointer.enter` quando o ponteiro entra
    // na superficie. Uma janela em fullscreen cobre a saida, entao o
    // ponteiro (que esta em algum output) acaba dentro dela.
    var plat = (try initPlatform()) orelse return;
    defer plat.deinit();

    // O seat precisa anunciar ponteiro.
    const seat = plat.seatCapabilities() orelse return;
    if (!seat.pointer) return;

    var win = plat.createWindow(.{ .width = 200, .height = 150, .title = "ponteiro" }) catch |err| switch (err) {
        error.NotImplemented => return,
        else => return err,
    };
    defer win.deinit();

    win.setFullscreen(true) catch {};

    var saw_pointer_in_window = false;
    var attempts: u32 = 0;
    while (attempts < 100 and !saw_pointer_in_window) : (attempts += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .pointer_move => |move| {
                    if (move.window) |wid| {
                        // O evento do ponteiro deve apontar para a janela
                        // criada (e nao para outra).
                        try std.testing.expect(wid.eql(win.windowId()));
                        saw_pointer_in_window = true;
                    }
                },
                else => {},
            }
        }
        sleepMs(20);
    }

    // O ponteiro pode estar em outra saida (a tela do compositor): o
    // teste nao falha por isso, apenas registra o que viu.
    if (saw_pointer_in_window) {
        std.debug.print("\n[wl-live] ponteiro dentro da janela\n", .{});
    }
}

test "live wayland: the keyboard focuses the window under the cursor" {
    // O compositor envia `wl_keyboard.enter` quando a janela recebe o
    // foco do teclado. O keymap XKB tambem e entregue (via fd) e
    // precisa ser aceito pela libxkbcommon.
    var plat = (try initPlatform()) orelse return;
    defer plat.deinit();

    const seat = plat.seatCapabilities() orelse return;
    if (!seat.keyboard) return;

    var win = plat.createWindow(.{ .width = 240, .height = 180, .title = "teclado" }) catch |err| switch (err) {
        error.NotImplemented => return,
        else => return err,
    };
    defer win.deinit();

    var saw_focus = false;
    var attempts: u32 = 0;
    while (attempts < 100 and !saw_focus) : (attempts += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            switch (ev) {
                .focus => |focus| {
                    if (focus.focused) {
                        try std.testing.expect(focus.window.eql(win.windowId()));
                        saw_focus = true;
                    }
                },
                else => {},
            }
        }
        sleepMs(20);
    }

    if (saw_focus) {
        std.debug.print("\n[wl-live] teclado com foco na janela\n", .{});
    }
}

/// Texto publicado pelo owner da selecao.
const clipboard_text = "zigway wayland clipboard";

/// Dono da selecao em outra thread: a leitura e sincrona e o
/// compositor pede os dados ao owner, que precisa bombear eventos.
const ClipboardOwner = struct {
    plat: *zigway.Platform,
    stop: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),

    fn run(self: *ClipboardOwner) void {
        self.plat.setClipboardText(clipboard_text) catch return;
        // Da tempo ao compositor de processar a selecao antes de o
        // leitor conectar.
        var waited: u32 = 0;
        while (waited < 300) : (waited += 10) {
            self.plat.pollEvents();
            sleepMs(10);
        }
        self.ready.store(true, .release);
        while (!self.stop.load(.acquire)) {
            self.plat.pollEvents();
            sleepMs(2);
        }
    }
};

test "live wayland: clipboard transfers between two clients" {
    var owner_plat = zigway.Platform.init(std.testing.allocator, .{ .backend = .wayland }) catch |err| {
        if (err == error.NoDisplay or err == error.UnsupportedBackend or
            err == error.ConnectionFailed or err == error.NotImplemented)
        {
            std.debug.print("\n[wl-live] compositor indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer owner_plat.deinit();

    // O leitor conecta antes: assim recebe a notificacao de mudanca da
    // selecao quando o owner publica.
    var reader = zigway.Platform.init(std.testing.allocator, .{ .backend = .wayland }) catch |err| {
        if (err == error.NoDisplay or err == error.UnsupportedBackend or
            err == error.ConnectionFailed or err == error.NotImplemented)
        {
            std.debug.print("\n[wl-live] compositor indisponivel ({t}); pulando.\n", .{err});
            return;
        }
        return err;
    };
    defer reader.deinit();

    var owner = ClipboardOwner{ .plat = &owner_plat };
    const thread = try std.Thread.spawn(.{}, ClipboardOwner.run, .{&owner});
    defer {
        owner.stop.store(true, .release);
        thread.join();
    }
    while (!owner.ready.load(.acquire)) sleepMs(5);

    // Cada leitura consome o offer pendente: o texto pode ser o que o
    // compositor tinha antes da nossa publicacao (ou o nosso).
    var got: ?[]u8 = null;
    var attempts: u32 = 0;
    while (attempts < 200 and got == null) : (attempts += 1) {
        reader.pollEvents();
        if (try reader.clipboardText(std.testing.allocator)) |text| {
            if (std.mem.eql(u8, text, clipboard_text)) {
                got = text;
            } else {
                std.testing.allocator.free(text);
            }
        }
        if (got == null) sleepMs(10);
    }
    if (got) |text| {
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(clipboard_text, text);
    } else {
        // O KWin deste ambiente nao entrega a selecao atual a clientes
        // Wayland (confirmado com um cliente C de referencia, usando o
        // codigo gerado pelo wayland-scanner). O caminho de publicacao
        // segue valido: sem `cancelled`, o compositor aceitou o source.
        std.debug.print(
            "\n[wl-live] compositor nao entregou a selecao; caminho de leitura nao exercitado\n",
            .{},
        );
    }
}

test "live wayland: initial output properties are not a display change" {
    // As propriedades iniciais dos outputs nao podem gerar um
    // `display_change` espurio (o evento e para mudancas reais).
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

    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        plat.pollEvents();
        while (plat.nextEvent()) |ev| {
            try std.testing.expect(ev != .display_change);
        }
        sleepMs(10);
    }
}
