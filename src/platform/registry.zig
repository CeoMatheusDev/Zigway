// Zigway Platform: registro de janelas (slots geracionais).
//
// Modulo-folha: importa apenas core + window. Os backends operam sobre o
// registro sem conhecer `Platform`, o que mantem o grafo de dependencias
// aciclico (a unica excecao documentada e o par Window <-> Platform).
//
// Handles nativos por backend:
//   - null: nenhum (native_ptr = null, native_id = 0).
//   - x11:  native_id = X11 Window (c_ulong); native_ptr = null.
//   - win32: native_ptr = HWND; native_id = 0.

const std = @import("std");
const types = @import("../core/types.zig");

pub const WindowId = types.WindowId;

pub const Slot = struct {
    // A geracao incrementa a cada reutilizacao do indice (wrapping em
    // 2^32 usos; ids antigos invalidam e nunca atingem outra janela).
    generation: u32 = 0,
    occupied: bool = false,
    should_close: bool = false,
    focused: bool = false,
    visible: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    native_ptr: ?*anyopaque = null,
    native_id: u64 = 0,
};

pub const Registry = struct {
    slots: std.ArrayList(Slot) = .empty,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    /// Reserva um slot e retorna (indice, id). Reutiliza slots livres;
    /// reutilizacao incrementa a geracao (ids antigos invalidam).
    pub fn allocSlot(self: *Registry, allocator: std.mem.Allocator) !struct {
        index: u32,
        id: WindowId,
    } {
        for (self.slots.items, 0..) |*slot, i| {
            if (!slot.occupied) {
                slot.occupied = true;
                slot.should_close = false;
                slot.focused = false;
                slot.visible = false;
                slot.width = 0;
                slot.height = 0;
                slot.native_ptr = null;
                slot.native_id = 0;
                return .{
                    .index = @intCast(i),
                    .id = .{ .index = @intCast(i), .generation = slot.generation },
                };
            }
        }
        if (self.slots.items.len >= std.math.maxInt(u32)) return error.InvalidConfig;
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(allocator, .{ .occupied = true });
        return .{ .index = index, .id = .{ .index = index, .generation = 0 } };
    }

    pub fn freeSlot(self: *Registry, id: WindowId) !void {
        const slot = self.get(id) orelse return error.InvalidWindow;
        slot.occupied = false;
        slot.generation +|= 1;
        slot.native_ptr = null;
        slot.native_id = 0;
    }

    pub fn get(self: *Registry, id: WindowId) ?*Slot {
        if (id.index >= self.slots.items.len) return null;
        const slot = &self.slots.items[id.index];
        if (!slot.occupied or slot.generation != id.generation) return null;
        return slot;
    }

    pub fn indexOf(self: *Registry, id: WindowId) ?u32 {
        if (self.get(id) == null) return null;
        return id.index;
    }

    pub fn idOf(self: *const Registry, index: u32) WindowId {
        return .{ .index = index, .generation = self.slots.items[index].generation };
    }
};

test "slot reuse bumps generation" {
    var reg = Registry{};
    defer reg.deinit(std.testing.allocator);
    const first = try reg.allocSlot(std.testing.allocator);
    try std.testing.expect(reg.get(first.id) != null);
    try reg.freeSlot(first.id);
    try std.testing.expect(reg.get(first.id) == null);
    const second = try reg.allocSlot(std.testing.allocator);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.id.generation == first.id.generation + 1);
    // Id antigo permanece invalido.
    try std.testing.expect(reg.get(first.id) == null);
    try std.testing.expectError(error.InvalidWindow, reg.freeSlot(first.id));
}
