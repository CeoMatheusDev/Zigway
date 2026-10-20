// Zigway: janela (handle logico sobre o recurso nativo).
//
// `Window` e um valor leve {id, platform}: nao detem memoria propria.
// Ownership: a janela nativa pertence a `Platform`; `deinit()` a destroi
// e invalida este handle (double-deinit e ignorado, nao falha).
//
// Nota arquitetural: este modulo importa `platform` apenas para o tipo
// *Platform (par Window <-> Platform documentado em docs/ARCHITECTURE.md);
// `platform` importa este modulo para Window/WindowConfig. Nao ha ciclo
// em nenhum outro nivel (backends nao conhecem Platform).

const std = @import("std");
const types = @import("core/types.zig");
const platform_mod = @import("platform/platform.zig");

pub const WindowId = types.WindowId;
pub const WindowSize = types.WindowSize;
pub const WindowPosition = types.WindowPosition;
pub const Cursor = types.Cursor;
pub const Platform = platform_mod.Platform;

pub const WindowConfig = struct {
    width: u32 = 1280,
    height: u32 = 720,
    title: []const u8 = "Zigway",
    resizable: bool = true,
    visible: bool = true,
};

pub const Window = struct {
    id: WindowId,
    platform: *Platform,

    pub fn windowId(self: Window) WindowId {
        return self.id;
    }

    pub fn isValid(self: Window) bool {
        return self.id.isValid() and self.platform.isWindowAlive(self.id);
    }

    /// Destroi a janela nativa e invalida este handle. Infalivel para
    /// uso com `defer`; janela invalida e ignorada.
    pub fn deinit(self: *Window) void {
        if (!self.id.isValid()) return;
        self.platform.destroyWindow(self.id) catch {};
        self.id = WindowId.invalid;
    }

    /// true se fechamento foi solicitado (ou handle invalido: falha
    /// segura para encerrar loops).
    pub fn shouldClose(self: Window) bool {
        return self.platform.windowShouldClose(self.id);
    }

    pub fn requestClose(self: Window) void {
        self.platform.requestWindowClose(self.id);
    }

    pub fn setTitle(self: Window, title: []const u8) !void {
        try self.platform.setWindowTitle(self.id, title);
    }

    pub fn setSize(self: Window, width: u32, height: u32) !void {
        try self.platform.setWindowSize(self.id, width, height);
    }

    /// Move a origem da area de cliente para (x, y) em coordenadas de tela.
    pub fn setPosition(self: Window, x: i32, y: i32) !void {
        try self.platform.setWindowPosition(self.id, x, y);
    }

    pub fn setVisible(self: Window, visible: bool) !void {
        try self.platform.setWindowVisible(self.id, visible);
    }

    pub fn focus(self: Window) !void {
        try self.platform.focusWindow(self.id);
    }

    pub fn setCursor(self: Window, cursor: Cursor) !void {
        try self.platform.setWindowCursor(self.id, cursor);
    }

    /// Captura o ponteiro para esta janela (exclusiva por `Platform`).
    /// Capturar outra janela da mesma instancia transfere a captura.
    pub fn capturePointer(self: Window) !void {
        try self.platform.captureWindowPointer(self.id);
    }

    /// Libera a captura se esta janela a detem; idempotente e infalivel.
    pub fn releasePointer(self: Window) void {
        self.platform.releaseWindowPointer(self.id);
    }

    pub fn size(self: Window) WindowSize {
        return self.platform.windowSize(self.id);
    }

    pub fn position(self: Window) WindowPosition {
        return self.platform.windowPosition(self.id);
    }
};
