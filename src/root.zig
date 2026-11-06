// Zigway: Native Platform Backend (Fase 1).
//
// API publica:
//
//   const zigway = @import("zigway");
//   var platform = try zigway.Platform.init(allocator, .{});
//   defer platform.deinit();
//   var window = try platform.createWindow(.{ .title = "Zigway" });
//   defer window.deinit();
//
// Documentacao: docs/. Estado real da implementacao (sem placeholders
// funcionais): Win32 + X11 na Fase 1; Wayland planejado (Fase 5).

const std = @import("std");

pub const version = @import("core/version.zig");
pub const errors = @import("core/errors.zig");
pub const caps = @import("core/caps.zig");

pub const types = @import("core/types.zig");
pub const WindowId = types.WindowId;
pub const DisplayId = types.DisplayId;
pub const DisplayModeId = types.DisplayModeId;
pub const DisplayInfo = types.DisplayInfo;
pub const DisplayMode = types.DisplayMode;
pub const SeatCapabilities = types.SeatCapabilities;
pub const Capabilities = types.Capabilities;
pub const Scale = types.Scale;
pub const PointerConstraint = types.PointerConstraint;
pub const ConstraintRegion = types.ConstraintRegion;
pub const BackendKind = types.BackendKind;
pub const ActiveBackend = types.ActiveBackend;
pub const Key = types.Key;
pub const MouseButton = types.MouseButton;
pub const Cursor = types.Cursor;
pub const Modifiers = types.Modifiers;
pub const WindowSize = types.WindowSize;
pub const WindowPosition = types.WindowPosition;

pub const platform_mod = @import("platform/platform.zig");
pub const Platform = platform_mod.Platform;
pub const PlatformOptions = platform_mod.Options;

pub const window_mod = @import("window.zig");
pub const Window = window_mod.Window;
pub const WindowConfig = window_mod.WindowConfig;
pub const WindowSizeLimits = types.WindowSizeLimits;

pub const events_mod = @import("events.zig");
pub const Event = events_mod.Event;
pub const EventQueue = events_mod.EventQueue;
pub const CloseEvent = events_mod.CloseEvent;
pub const ResizeEvent = events_mod.ResizeEvent;
pub const MoveEvent = events_mod.MoveEvent;
pub const DisplayChangeEvent = events_mod.DisplayChangeEvent;
pub const FullscreenEvent = events_mod.FullscreenEvent;
pub const MaximizedEvent = events_mod.MaximizedEvent;
pub const TextInputEvent = events_mod.TextInputEvent;
pub const CompositionStartEvent = events_mod.CompositionStartEvent;
pub const CompositionEndEvent = events_mod.CompositionEndEvent;
pub const ScaleChangedEvent = events_mod.ScaleChangedEvent;
pub const SurroundingDeleteEvent = events_mod.SurroundingDeleteEvent;
pub const PointerRelativeEvent = events_mod.PointerRelativeEvent;
pub const PointerConstraintEvent = events_mod.PointerConstraintEvent;
pub const RawKeyEvent = events_mod.RawKeyEvent;
pub const FocusEvent = events_mod.FocusEvent;
pub const KeyEvent = events_mod.KeyEvent;
pub const PointerMoveEvent = events_mod.PointerMoveEvent;
pub const PointerButtonEvent = events_mod.PointerButtonEvent;
pub const ScrollEvent = events_mod.ScrollEvent;

pub const input_mod = @import("input.zig");
pub const InputState = input_mod.InputState;

pub const native = @import("core/native.zig");
pub const NativeHandle = native.NativeHandle;

/// Contexto OpenGL (EGL) por janela; nao e um renderer (docs/GRAPHICS.md).
pub const gl = @import("gl.zig");

test {
    // Agrega os testes unitarios de todos os modulos.
    std.testing.refAllDecls(@This());
    _ = @import("core/version.zig");
    _ = @import("core/handles.zig");
    _ = @import("core/types.zig");
    _ = @import("core/caps.zig");
    _ = @import("core/native.zig");
    _ = @import("gl.zig");
    _ = @import("events.zig");
    _ = @import("input.zig");
    _ = @import("window.zig");
    _ = @import("platform/registry.zig");
    _ = @import("platform/backend.zig");
    _ = @import("platform/config.zig");
    _ = @import("platform/platform.zig");
    _ = @import("platform/null_backend.zig");
    _ = @import("platform/x11/api.zig");
    _ = @import("platform/x11/backend.zig");
    _ = @import("platform/win32/api.zig");
    _ = @import("platform/win32/backend.zig");
}
