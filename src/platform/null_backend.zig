// Zigway Platform: backend headless ("null").
//
// Sem recursos nativos. Janelas existem apenas no registro; eventos chegam
// via injecao (`Platform.injectEvent`), o que permite testar lifecycle,
// fila e input sem display. Tambem e o fallback em SOs sem backend nativo.

const std = @import("std");
const registry = @import("registry.zig");
const events = @import("../events.zig");
const input = @import("../input.zig");
const window = @import("../window.zig");
const types = @import("../core/types.zig");

pub const Backend = struct {
    allocator: std.mem.Allocator,
    /// Slot com captura de ponteiro (exclusiva), se houver.
    captured: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Backend) void {
        _ = self;
    }

    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        _ = self;
        const entry = &reg.slots.items[slot];
        entry.width = cfg.width;
        entry.height = cfg.height;
        entry.visible = cfg.visible;
        entry.native_ptr = null;
        entry.native_id = 0;
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured == slot) self.captured = null;
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        _ = self;
        _ = reg;
        _ = queue;
        _ = state;
    }

    pub fn setTitle(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        title: []const u8,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = title;
    }

    pub fn setSize(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        width: u32,
        height: u32,
    ) !void {
        _ = self;
        reg.slots.items[slot].width = width;
        reg.slots.items[slot].height = height;
    }

    pub fn setVisible(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        visible: bool,
    ) !void {
        _ = self;
        reg.slots.items[slot].visible = visible;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = self;
        _ = reg;
        _ = slot;
    }

    pub fn setCursor(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cursor: types.Cursor,
    ) !void {
        _ = self;
        _ = reg;
        _ = slot;
        _ = cursor;
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        self.captured = slot;
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured == slot) self.captured = null;
    }
};
