// Zigway Core: capacidades compiladas vs. disponiveis em runtime.
//
// Capacidade compilada (!= disponivel): um backend pode estar presente no
// binario mas falhar em runtime (ex.: X11 compilado sem DISPLAY).
// Consumidores devem tratar erros de init; nunca presumir disponibilidade.

const std = @import("std");
const types = @import("types.zig");

/// Capacidades conhecidas em tempo de compilacao.
pub const CompileCaps = struct {
    has_win32: bool,
    has_x11: bool,
    has_wayland: bool,
    multi_window: bool,
};

pub const compile_caps: CompileCaps = .{
    .has_win32 = switch (builtin.os.tag) {
        .windows => true,
        else => false,
    },
    .has_x11 = switch (builtin.os.tag) {
        .linux => true,
        else => false,
    },
    // Backend Wayland nativo compilado no Linux (v0.5 em andamento:
    // conexao/registry/outputs/seat; janelas ainda nao).
    .has_wayland = builtin.os.tag == .linux,
    .multi_window = true,
};

/// Capacidades efetivas da instancia em uso.
pub const RuntimeCaps = struct {
    backend: types.ActiveBackend,
    multi_window: bool,
    max_title_bytes: usize,

    pub fn forBackend(backend: types.ActiveBackend) RuntimeCaps {
        return .{
            .backend = backend,
            .multi_window = true,
            .max_title_bytes = 1024,
        };
    }
};

const builtin = @import("builtin");

test "wayland backend is compiled only on linux" {
    try std.testing.expectEqual(builtin.os.tag == .linux, compile_caps.has_wayland);
}

test "host backend matches compile caps" {
    if (builtin.os.tag == .linux) try std.testing.expect(compile_caps.has_x11);
    if (builtin.os.tag == .windows) try std.testing.expect(compile_caps.has_win32);
}
