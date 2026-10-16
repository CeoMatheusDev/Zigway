// Zigway Core: identificadores estaveis (handles geracionais).
//
// WindowId combina indice + geracao: reutilizar um slot incrementa a
// geracao, de modo que ids antigos sao rejeitados em vez de atingirem
// silenciosamente uma janela diferente (fail-fast contra use-after-free
// logico).

pub const WindowId = struct {
    index: u32,
    generation: u32,

    pub const invalid: WindowId = .{ .index = std.math.maxInt(u32), .generation = 0 };

    pub fn eql(a: WindowId, b: WindowId) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn eqlOpt(a: ?WindowId, b: ?WindowId) bool {
        if (a) |av| {
            if (b) |bv| return av.eql(bv);
            return false;
        }
        return b == null;
    }

    pub fn isValid(self: WindowId) bool {
        return !self.eql(invalid);
    }
};

/// Identificador opaco de monitor. Reservado para a Fase 2 (Display).
pub const DisplayId = struct {
    raw: u32,

    pub const invalid: DisplayId = .{ .raw = std.math.maxInt(u32) };
};

const std = @import("std");

test "WindowId equality and invalid sentinel" {
    const a: WindowId = .{ .index = 1, .generation = 2 };
    const b: WindowId = .{ .index = 1, .generation = 2 };
    const c: WindowId = .{ .index = 1, .generation = 3 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!WindowId.invalid.isValid());
    try std.testing.expect(a.isValid());
}
