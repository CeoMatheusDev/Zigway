<div align="center">

# Zigway

**Native platform backend for game engines. Pure Zig.**

A lightweight, native platform layer for desktop applications and game engines, built in Zig without `@cImport`, C headers, or external runtime dependencies.

Built for Zig 0.17.0 • Current version **0.1.0-alpha.1**

[![Status](https://img.shields.io/badge/status-alpha-orange)](https://github.com/CeoMatheusDev/Zigway)
[![Zig](https://img.shields.io/badge/Zig-0.17.0-f7a41d)](https://ziglang.org/)
[![Platform](https://img.shields.io/badge/backends-Win32%20%7C%20X11%20%7C%20null-4b8bbe)](https://github.com/CeoMatheusDev/Zigway)
[![License](https://img.shields.io/badge/license-MIT-blue)](https://github.com/CeoMatheusDev/Zigway/blob/main/LICENSE)

</div>

---

## Overview

Zigway provides a native windowing and input abstraction layer for game engines, GUI toolkits, and desktop applications. It is designed around Zig-first APIs with explicit ownership, generated handles, and zero global state.

This project targets a clean separation between platform backend concerns and graphics/RHI concerns. Zigway manages windows, events, and input, while rendering and device integration remain outside this layer.

> [!IMPORTANT]
> Wayland is not implemented and is explicitly not advertised as available. This repository currently supports Win32, X11, and a null/headless backend only.

## Why Zigway

- Native Zig API: explicit error sets, strong types, and structured event handling.
- Multi-window support: multiple windows can coexist in a single platform instance.
- Generated handles: stale IDs fail safely instead of referring to the wrong window.
- Caller-owned memory model: no hidden global state, predictable lifetime semantics.
- Headless testing: null backend for CI and display-free validation.
- Platform-focused scope: no renderer, no GPU pipeline, no fake abstraction layers.

## Supported backends

| Platform | Backend | Status |
| --- | --- | --- |
| Windows | Win32 | Implemented |
| Linux | X11 | Implemented |
| Any | Null/headless | Implemented for tests and CI |
| Linux | Wayland | Planned, not implemented |

The current implementation is intentionally conservative: support is only declared when it is validated in code and build/test flow.

## Requirements

- Zig 0.17.0
- Linux/X11: system X11 headers and libraries
- Windows: standard Win32 SDK

## Build and test

```bash
zig build              # build the library
zig build test         # headless unit tests
zig build test-x11     # X11 integration tests (skips without a display)
zig build examples     # example apps
zig fmt --check .      # formatting validation
```

Backend selection:

```bash
zig build -Dplatform=x11          # Linux/X11
zig build -Dplatform=win32        # Windows backend
zig build -Dplatform=null_backend # headless backend
```

Cross-compilation for Windows:

```bash
zig build -Dtarget=x86_64-windows -Dplatform=win32
```

See `docs/BUILDING.md` for backend details and troubleshooting.

## Example

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
            .close => |e| if (e.window.eql(window.windowId()))
                window.requestClose(),
            .key_down => |e| if (e.key == .escape)
                window.requestClose(),
            else => {},
        }
    }
    // Rendering...
}
```

## Dependency usage

Local path dependency:

```zig
.dependencies = .{
    .zigway = .{ .path = "../zigway" },
},
```

```zig
const zigway_dep = b.dependency("zigway", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigway", zigway_dep.module("zigway"));
```

Remote fetch from a published tag is pending the first official release. No tarball is published yet.

## Roadmap

- Implemented in v0.1.0-alpha.1: core platform foundation, windowing, events, input, Win32, X11, null backend
- In progress: validation, CI stability, runtime checks
- Planned: input expansion, text/clipboard, display/cursor work, Wayland evaluation, C ABI and broader portability

## Documentation

- `docs/BUILDING.md` — build steps, dependencies, platform notes
- `docs/ARCHITECTURE.md` — layers, ownership and backend boundaries
- `docs/API.md` — public API reference
- `docs/BACKENDS.md` — backend coverage and current limitations
- `docs/ROADMAP.md` — planned milestones
- `CHANGELOG.md` — change history

## Contributing

Contributions are welcome, especially around validation, cross-platform behavior, cleanup, and documentation.

Please follow the repository conventions and keep changes focused. Commit messages should use conventional commit style, and any functional change should be reflected in the changelog.

## License

MIT — see `LICENSE`.

---

<div align="center">

**Zigway** · Native platform backend for game engines and desktop apps

</div>
