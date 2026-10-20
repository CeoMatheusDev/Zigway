// Zigway: wakeup para o loop de eventos.
//
// Um "wakeup" e um par de descritores (self-pipe): `signal` escreve um
// byte e `drain` le/esvazia. O backend de eventos espera no descritor
// de leitura junto com o descritor da conexao nativa, entao outra
// thread pode acordar o loop sem busy-wait.
//
// Somente POSIX (X11/Wayland). O backend Win32 usa um evento do
// kernel32 e o backend null nao espera.

const std = @import("std");

pub const Wakeup = struct {
    /// Descritor de leitura (o loop espera aqui).
    read_fd: c_int = -1,
    /// Descritor de escrita (o `signal` escreve aqui).
    write_fd: c_int = -1,
    /// Fechado: impede `signal` de escrever num descritor reciclado.
    closed: std.atomic.Value(bool) = .init(false),

    pub fn init() !Wakeup {
        var fds: [2]c_int = undefined;
        // `pipe2` com O_CLOEXEC: os descritores nao vazam para filho.
        const flags: std.os.linux.O = .{ .CLOEXEC = true };
        const rc = std.c.pipe2(&fds, flags);
        if (rc != 0) return error.Unexpected;
        // A ponta de leitura nao pode bloquear: `drain` le ate ficar vazio
        // e nao pode esperar por dados que nao existirao.
        const current = std.os.linux.fcntl(fds[0], std.os.linux.F.GETFL, 0);
        const nonblock = current | 0o4000; // O_NONBLOCK
        _ = std.os.linux.fcntl(fds[0], std.os.linux.F.SETFL, nonblock);
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    pub fn deinit(self: *Wakeup) void {
        // Marca antes de fechar: um `signal` concorrente ve o flag e nao
        // escreve (evita escrever num descritor reciclado).
        self.closed.store(true, .release);
        if (self.read_fd >= 0) {
            _ = std.c.close(self.read_fd);
            self.read_fd = -1;
        }
        if (self.write_fd >= 0) {
            _ = std.c.close(self.write_fd);
            self.write_fd = -1;
        }
    }

    /// Acorda quem esta esperando.
    pub fn signal(self: *const Wakeup) void {
        if (self.write_fd < 0) return;
        if (self.closed.load(.acquire)) return;
        const byte = [_]u8{0};
        // Um byte basta: o leitor drena tudo.
        _ = std.c.write(self.write_fd, &byte, 1);
    }

    /// Esvazia o pipe (chamar depois de acordar).
    pub fn drain(self: *const Wakeup) void {
        if (self.read_fd < 0) return;
        var buf: [64]u8 = undefined;
        while (true) {
            const n = std.posix.read(self.read_fd, &buf) catch return;
            if (n == 0) return;
        }
    }
};

/// Sinalizador repetido (usado no teste de concorrencia).
const Signaler = struct {
    wake: *Wakeup,
    fn run(self: *Signaler) void {
        var i: u32 = 0;
        while (i < 50) : (i += 1) {
            self.wake.signal();
        }
    }
};

test "concurrent wakeups are coalesced and drained" {
    var wake = try Wakeup.init();
    defer wake.deinit();

    // Varias threads sinalizam ao mesmo tempo: o pipe acumula bytes e o
    // leitor drena tudo de uma vez.
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        var signaler = Signaler{ .wake = &wake };
        t.* = try std.Thread.spawn(.{}, Signaler.run, .{&signaler});
    }
    for (threads) |t| t.join();

    // Ha dados pendentes (o pipe nao transborda com 200 bytes).
    var fds = [_]std.posix.pollfd{.{
        .fd = wake.read_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, 100);
    try std.testing.expectEqual(@as(usize, 1), ready);
    wake.drain();

    // Depois do drain nao ha mais dados.
    const ready_after = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), ready_after);
}

test "wakeup after deinit does not write to a recycled descriptor" {
    var wake = try Wakeup.init();
    wake.deinit();
    // Nao pode escrever (o descritor foi fechado).
    wake.signal();
    try std.testing.expect(wake.closed.load(.acquire));
}

test "wakeup signals and drains" {
    var wake = try Wakeup.init();
    defer wake.deinit();

    // Sem sinal, nao ha leitura pendente.
    var fds = [_]std.posix.pollfd{.{
        .fd = wake.read_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), ready);

    wake.signal();
    const ready_after = try std.posix.poll(&fds, 50);
    try std.testing.expectEqual(@as(usize, 1), ready_after);
    wake.drain();

    // Apos drenar, nao ha mais leitura pendente.
    const ready_drained = try std.posix.poll(&fds, 0);
    try std.testing.expectEqual(@as(usize, 0), ready_drained);
}
