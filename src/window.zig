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
const native_types = @import("core/native.zig");
const platform_mod = @import("platform/platform.zig");

pub const WindowId = types.WindowId;
pub const WindowSize = types.WindowSize;
pub const WindowPosition = types.WindowPosition;
pub const WindowSizeLimits = types.WindowSizeLimits;
pub const Scale = types.Scale;
pub const PointerConstraint = types.PointerConstraint;
pub const ConstraintRegion = types.ConstraintRegion;
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

    /// Define limites minimo/maximo da area de cliente. Zero em `max_*`
    /// significa sem limite explicito naquele eixo. O WM pode ajustar a
    /// aplicacao.
    pub fn setSizeLimits(self: Window, limits: WindowSizeLimits) !void {
        try self.platform.setWindowSizeLimits(self.id, limits);
    }

    /// Limites configurados (falha segura: zero para id invalido).
    pub fn sizeLimits(self: Window) WindowSizeLimits {
        return self.platform.windowSizeLimits(self.id);
    }

    /// Move a origem da area de cliente para (x, y) em coordenadas de tela.
    pub fn setPosition(self: Window, x: i32, y: i32) !void {
        try self.platform.setWindowPosition(self.id, x, y);
    }

    /// Solicita/remove fullscreen. No X11 com EWMH e assincrono: o evento
    /// `fullscreen` confirma o estado. Sem WM/EWMH usa geometria de fallback.
    pub fn setFullscreen(self: Window, fullscreen: bool) !void {
        try self.platform.setWindowFullscreen(self.id, fullscreen);
    }

    /// Estado de fullscreen atual (falha segura: false para id invalido).
    pub fn isFullscreen(self: Window) bool {
        return self.platform.isWindowFullscreen(self.id);
    }

    /// Solicita/remove maximizacao. X11/EWMH confirma via evento; sem
    /// WM/EWMH usa geometria de fallback. Fullscreen e maximizado sao
    /// mutuamente exclusivos.
    pub fn setMaximized(self: Window, maximized: bool) !void {
        try self.platform.setWindowMaximized(self.id, maximized);
    }

    /// Estado de maximizacao atual (falha segura: false para id invalido).
    pub fn isMaximized(self: Window) bool {
        return self.platform.isWindowMaximized(self.id);
    }

    pub fn setVisible(self: Window, visible: bool) !void {
        try self.platform.setWindowVisible(self.id, visible);
    }

    pub fn focus(self: Window) !void {
        try self.platform.focusWindow(self.id);
    }

    /// Handle nativo emprestado da janela, para integrar APIs graficas
    /// externas (ver `zigway.gl`). `error.NotImplemented` quando o
    /// backend ativo nao o expoe (hoje so o X11 expoe).
    pub fn nativeHandle(self: Window) !native_types.NativeHandle {
        return self.platform.windowNativeHandle(self.id);
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

    /// Tamanho logico da area de cliente (unidades de superficie).
    pub fn size(self: Window) WindowSize {
        return self.platform.windowSize(self.id);
    }

    /// Tamanho fisico do buffer da janela (pixels da tela): o tamanho
    /// logico multiplied pela escala. No X11 e no Win32 coincide com
    /// `size()` (escala 1:1 no cliente); no Wayland com escala
    /// fracionaria o buffer e maior que o tamanho logico.
    pub fn bufferSize(self: Window) WindowSize {
        return self.platform.windowBufferSize(self.id);
    }

    /// Informa ao IME o texto ao redor do cursor (contexto textual).
    /// `cursor` e o deslocamento (em bytes UTF-8) dentro de `text`.
    pub fn setSurroundingText(self: Window, text: []const u8, cursor: u32) !void {
        try self.platform.setWindowSurroundingText(self.id, text, cursor);
    }

    /// Aplica (ou remove) uma restricao de ponteiro nesta janela
    /// (`lock`, `confine` com a regiao ou `none`).
    pub fn setPointerConstraint(
        self: Window,
        constraint: PointerConstraint,
        region: ?ConstraintRegion,
    ) !void {
        try self.platform.setWindowPointerConstraint(self.id, constraint, region);
    }

    /// Restricao de ponteiro ativa nesta janela.
    pub fn pointerConstraint(self: Window) PointerConstraint {
        return self.platform.windowPointerConstraint(self.id);
    }

    /// Escala de exibicao da janela (1/1 = 100%). No Wayland pode ser
    /// fracionaria (ex.: 3/2 = 150%).
    pub fn scale(self: Window) Scale {
        return self.platform.windowScale(self.id);
    }

    pub fn position(self: Window) WindowPosition {
        return self.platform.windowPosition(self.id);
    }
};
