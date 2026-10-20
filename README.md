<div align="center">

# Zigway

**Native windows. Explicit control. Pure Zig.**

A lightweight, renderer-independent platform layer for desktop applications and GUI toolkits, written in Zig with direct native API bindings.

**Zig 0.17.0** · **v0.1.0-alpha.2** · **Alpha**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Status](https://img.shields.io/badge/status-alpha-F59E0B)](https://github.com/CeoMatheusDev/Zigway)
[![Backends](https://img.shields.io/badge/backends-Win32%20%7C%20X11%20%7C%20headless-2563EB)](docs/BACKENDS.md)
[![License: MIT](https://img.shields.io/badge/license-MIT-22C55E)](LICENSE)

[Overview](#overview) · [Features](#why-zigway) · [Backends](#backend-support) · [Getting started](#getting-started) · [Documentation](#documentation)

</div>

---

## Overview

**Zigway** provides the native windowing, event, and input layer for desktop software built with Zig. It offers a consistent Zig API over platform-specific backends while keeping ownership, lifetimes, and errors explicit.

It is designed to sit **below a renderer or GUI toolkit**: Zigway manages windows and dispatches input; your application chooses how to draw, which graphics API to use, and how to organize its UI.

The core uses hand-declared native ABI bindings instead of `@cImport` or third-party Zig packages. Platform system libraries are still linked where required (such as X11 on Linux and Win32 libraries on Windows).

> [!IMPORTANT]
> **Early alpha:** Zigway is currently at `v0.1.0-alpha.2`. Win32 and X11 backends are implemented, but runtime validation is not equivalent across platforms: X11 has been tested with a live display, while Win32 has been cross-compiled but not runtime-tested on Windows. The **native Wayland backend is in progress**: compositor connection, outputs, seat, xdg-shell windows and pointer/keyboard input work, while the Wayland clipboard and Unicode text input are still pending.

## Why Zigway?

- **Zig-native interface:** Strongly typed events, explicit error handling, and allocator-aware APIs.
- **Multiple windows:** Manage several native windows within a single `Platform` instance.
- **Safer handles:** Generational window IDs prevent stale handles from silently targeting reused slots.
- **No global platform state:** Ownership and lifetime are scoped to your `Platform` and `Window` values.
- **Backend-neutral input:** Consume normalized keyboard, mouse, focus, resize, and close events.
- **Native cursors:** Apply standard system cursors per window without depending on a renderer.
- **Pointer capture:** Keep receiving pointer input for a window beyond its bounds, with explicit release.
- **Monitor enumeration:** Query active display outputs and their geometry through one allocator-aware API, with native backends and a headless empty result.
- **Display change notifications:** Receive a normalized event when the display configuration changes, then re-query the monitor snapshot.
- **Window positioning:** Move windows by client-area coordinates and receive normalized move events; X11 uses EWMH when the window manager advertises it.
- **Fullscreen:** Toggle a window into fullscreen and observe the confirmed state; X11 uses EWMH with a geometry fallback, Win32 uses a borderless popup over the nearest monitor.
- **Native Wayland:** A real Wayland backend (not XWayland): compositor connection, registry, outputs, seat capabilities, xdg-shell windows (title, size limits, maximize, fullscreen) and pointer/keyboard input; the Wayland clipboard and Unicode text input are still pending.
- **Raw input:** Hardware-level key events (`raw_key`) exposing the physical scancode — the X11 keycode or the Windows scan code — so apps can tell left/right modifiers apart and stay layout independent.
- **Text input:** Unicode text input separated from the raw key events (`text_input` carries one codepoint per event); on X11 it comes from the keysym, on Windows from `WM_CHAR` (the IME commit path).
- **Clipboard:** Read and write UTF-8 text on the system clipboard; on X11 the platform owns the `CLIPBOARD` selection and serves `SelectionRequest` (`UTF8_STRING`, `text/plain`, `STRING`/Latin-1) with target fallback on read, on Windows it uses `CF_UNICODETEXT`.
- **Video modes:** List the modes of a display and switch resolution on X11 via RandR (`XRRSetCrtcConfig`, with native readback) and on Windows via `EnumDisplaySettingsW`/`ChangeDisplaySettingsExW`; the null backend reports no modes.
- **Maximize:** Maximize and restore windows with normalized events; X11 uses EWMH with a geometry fallback, Win32 uses `ShowWindow`/`IsZoomed`, and fullscreen/maximize are mutually exclusive.
- **Size limits:** Set client-area minimum and maximum dimensions; X11 publishes `WM_NORMAL_HINTS`, Win32 handles `WM_GETMINMAXINFO`, and the null backend keeps the state logical.
- **Headless operation:** Use the null backend to exercise platform logic without a desktop session.
- **Rendering freedom:** Integrate your preferred graphics API or UI toolkit without a bundled renderer.

## Backend support

| Environment | Backend | Implementation | Validation |
| --- | --- | --- | --- |
| Windows | Win32 | Implemented | Cross-compilation; native runtime validation pending |
| Linux | X11 | Implemented | Live-display integration tests |
| Headless / CI | Null | Implemented | Unit tests and event injection |
| Linux | Native Wayland | In progress | Live-compositor integration tests (windows, outputs, seat) |

XWayland can run the **X11** backend; this does not constitute native Wayland support.

For platform-specific behavior and limitations, read [Backend coverage](docs/BACKENDS.md).

## Architecture

Zigway deliberately separates platform responsibilities from rendering and graphics-device management.

```text
Application / GUI toolkit / renderer
                │
                ▼
         Zigway public API
                │
       ┌────────┴─────────┐
       │                  │
  Window & input     Event queue
       │                  │
       └────────┬─────────┘
                ▼
         Platform backend
       ┌────────┼─────────┐
       ▼        ▼         ▼
     Win32     X11      Null
```

The repository keeps the implementation in focused modules:

- `src/core/` — types, errors, capabilities, and generational handles
- `src/events.zig` and `src/input.zig` — normalized events and input state
- `src/platform/` — backend implementations and platform orchestration
- `src/window.zig` — window handle API

**Not included:** a renderer, graphics hardware abstraction, GPU device, or rendering pipeline. Those remain application-level decisions.

## Getting started

### Requirements

- **Zig 0.17.0**
- **Linux/X11:** X11 development headers and system libraries for building and linking. At runtime, `libXrandr.so.2` (RandR 1.5+) is optional for physical monitor enumeration; without it, Zigway reports X screens.
- **Windows:** the Win32 system libraries and toolchain support needed by the target

### Build and test

Clone the repository and run:

```sh
zig build               # Build the library
zig build test          # Run headless unit tests
zig build test-x11      # Run live X11 integration tests (requires a display)
zig build examples      # Build the example programs
zig fmt --check .       # Check Zig formatting
```

Two extra steps exist for the Windows backend and for video modes:

```sh
zig build test-win32-compile  # Compile (do not run) the tests for Windows
zig build test-x11-modes      # Live video-mode switch (CHANGES the resolution)
zig build test-wayland        # Live Wayland test (skips without a compositor)
```

The live X11 test is designed to skip when a display is unavailable. Consult [Building](docs/BUILDING.md) for environment setup and troubleshooting.

### Select a backend

Backend selection is a build-time option. The default is `auto`.

```sh
zig build -Dplatform=auto
zig build -Dplatform=x11
zig build -Dplatform=null_backend
```

For a Windows target:

```sh
zig build -Dtarget=x86_64-windows -Dplatform=win32
```

The build rejects incompatible backend/target combinations and rejects `-Dplatform=wayland` because that backend is not implemented.

### Minimal window loop

```zig
const zigway = @import("zigway");

var platform = try zigway.Platform.init(allocator, .{});
defer platform.deinit();

var window = try platform.createWindow(.{
    .width = 1280,
    .height = 720,
    .title = "Zigway",
    .resizable = true,
});
defer window.deinit();

while (!window.shouldClose()) {
    platform.pollEvents();

    while (platform.nextEvent()) |event| {
        switch (event) {
            .close => |e| {
                if (e.window.eql(window.windowId())) window.requestClose();
            },
            .key_down => |e| {
                if (e.key == .escape) window.requestClose();
            },
            else => {},
        }
    }

    // Render with your application's graphics backend.
}
```

This is a platform/event-loop example, **not** a renderer. See the runnable examples for full project integration.

## Use Zigway as a dependency

For a local checkout, add a path dependency to your `build.zig.zon`:

```zig
.dependencies = .{
    .zigway = .{ .path = "../zigway" },
},
```

Then expose the module to your application in `build.zig`:

```zig
const zigway_dep = b.dependency("zigway", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigway", zigway_dep.module("zigway"));
```

A published release archive is not yet available; use a local dependency until an official downloadable release is published.

## Examples

The repository includes six example programs:

| Example | Purpose |
| --- | --- |
| [`hello_window.zig`](examples/hello_window.zig) | Create and manage a native window |
| [`multiple_windows.zig`](examples/multiple_windows.zig) | Work with more than one window |
| [`keyboard_input.zig`](examples/keyboard_input.zig) | Handle keyboard events |
| [`displays.zig`](examples/displays.zig) | List monitors and their geometry |
| [`display_change.zig`](examples/display_change.zig) | React to display configuration changes |
| [`fullscreen.zig`](examples/fullscreen.zig) | Toggle fullscreen with F11 |

Build all examples with `zig build examples`.

## Roadmap

**Available in the current alpha:** the core platform API, window lifecycle, event/input handling, generational handles, Win32, X11, and a null backend.

**Ongoing:** platform validation, CI reliability, and runtime hardening.

**Planned / under consideration:** expanded input capabilities, text and clipboard integration, display and cursor functionality, native Wayland, and an optional isolated C ABI.

See the [roadmap](docs/ROADMAP.md) for the latest development milestones. Planned items are **not** part of the current public API.

## Documentation

- [Building](docs/BUILDING.md) — toolchain, dependencies, and backend configuration
- [Architecture](docs/ARCHITECTURE.md) — ownership and subsystem boundaries
- [API reference](docs/API.md) — public types and operations
- [Backend coverage](docs/BACKENDS.md) — implementation status and limitations
- [Roadmap](docs/ROADMAP.md) — upcoming milestones
- [Changelog](CHANGELOG.md) — version history
- [Contributing](CONTRIBUTING.md) — contribution guidelines
- [Security](SECURITY.md) — reporting security issues

## License

Zigway is distributed under the [MIT License](LICENSE).

---

<div align="center">

**Zigway** · Native windowing · Explicit ownership · Renderer-independent

</div>
