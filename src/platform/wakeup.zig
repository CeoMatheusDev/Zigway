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
