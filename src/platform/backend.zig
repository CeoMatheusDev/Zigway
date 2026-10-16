// Zigway Platform: selecao e resolucao de backend.
//
// `BackendKind` (publico) inclui `.auto` e placeholders futuros;
// `ActiveBackend` e o conjunto efetivamente instanciavel.
// Regras:
//   - `.auto` -> padrao do build (-Dplatform) ou padrao do SO.
//   - `.wayland` -> sempre error.NotImplemented (Fase 5 do roadmap).
//   - backend de outro SO -> error.UnsupportedBackend.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../core/types.zig");
const config = @import("config.zig");

pub const BackendKind = types.BackendKind;
pub const ActiveBackend = types.ActiveBackend;

/// Backend padrao para `.auto` neste alvo.
pub fn defaultForCurrentTarget() ActiveBackend {
    if (config.build_default != .auto) {
        return switch (config.build_default) {
            .win32 => .win32,
            .x11 => .x11,
            .null_backend => .null_backend,
            .auto, .wayland => unreachable,
        };
    }
    return switch (builtin.os.tag) {
        .windows => .win32,
        .linux => .x11,
        else => .null_backend,
    };
}

pub fn isAvailable(backend: ActiveBackend) bool {
    return switch (backend) {
        .win32 => builtin.os.tag == .windows,
        .x11 => builtin.os.tag == .linux,
        .null_backend => true,
    };
}

pub fn resolve(requested: BackendKind) !ActiveBackend {
    switch (requested) {
        .auto => {
            const backend = defaultForCurrentTarget();
            if (!isAvailable(backend)) return error.UnsupportedBackend;
            return backend;
        },
        .wayland => return error.NotImplemented,
        .win32 => {
            if (!isAvailable(.win32)) return error.UnsupportedBackend;
            return .win32;
        },
        .x11 => {
            if (!isAvailable(.x11)) return error.UnsupportedBackend;
            return .x11;
        },
        .null_backend => return .null_backend,
    }
}

test "resolve auto on host" {
    const backend = try resolve(.auto);
    if (builtin.os.tag == .linux) try std.testing.expectEqual(ActiveBackend.x11, backend);
    if (builtin.os.tag == .windows) try std.testing.expectEqual(ActiveBackend.win32, backend);
}

test "resolve wayland is never implemented" {
    try std.testing.expectError(error.NotImplemented, resolve(.wayland));
}

test "resolve foreign backend is unsupported" {
    if (builtin.os.tag == .linux) {
        try std.testing.expectError(error.UnsupportedBackend, resolve(.win32));
    }
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.UnsupportedBackend, resolve(.x11));
    }
    // null_backend sempre disponivel.
    try std.testing.expectEqual(ActiveBackend.null_backend, try resolve(.null_backend));
}
