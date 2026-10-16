# Zigway — Native Platform Backend for Game Engines

Biblioteca em Zig 0.17.0 que abstrai o sistema de janelas nativo
(Win32, X11) para game engines, GUIs e aplicações nativas. Sem
dependências externas, sem `@cImport`: as ABIs nativas são declaradas
manualmente em Zig.

> Estado: **v0.1.0-alpha.1** — fundação, janelas, eventos e input sobre
> Win32 + X11. Wayland, gráficos e ABI C seguem o roadmap abaixo.

## Requisitos

- Zig **0.17.0** (`zig version` deve reportar `0.17.0`).
- Linux: Xlib de desenvolvimento (`libX11.so` + headers X11).
- Windows: SDK padrão (kernel32/user32/gdi32).

## Uso rápido

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

## Build

```bash
zig build              # biblioteca + validacao do alvo
zig build test         # testes unitarios (headless, sem display)
zig build test-x11     # teste live X11 (requer display; pula sem ele)
zig build examples     # hello_window, multiple_windows, keyboard_input

zig build -Dplatform=x11       # Linux: padrao X11
zig build -Dplatform=win32     # Windows: padrao Win32
zig build -Dplatform=null_backend  # headless (CI, testes de logica)
```

## Backends

| Backend | Estado (v0.1.0-alpha.1) | Notas |
|---|---|---|
| Win32 | implementado | validado por compilação cruzada; runtime pendente de Windows real |
| X11 | implementado e validado | testado com display real (`zig build test-x11`) |
| Wayland | **não implementado** | `error.NotImplemented`; ver `src/platform/wayland/README.md` |
| null | implementado | headless; testes e fallback |

## Layout

```text
src/
  root.zig            API pública
  core/               version, errors, types, handles, caps
  events.zig          Event (union), EventQueue, dispatch
  input.zig           InputState (teclado + ponteiro)
  window.zig          Window (handle) + WindowConfig
  platform/
    platform.zig      Platform (multi-janelas, fila, input)
    backend.zig       resolução auto/win32/x11/wayland/null
    registry.zig      slots geracionais
    null_backend.zig  headless
    x11/              api.zig (ABI manual) + backend.zig
    win32/            api.zig (ABI manual) + backend.zig
    wayland/          README de status (sem código)
examples/zig/        hello_window, multiple_windows, keyboard_input
tests/live_x11.zig   teste live (display real)
docs/                architecture, getting-started, backends, versioning
```

## Documentação

- `docs/getting-started.md` — primeiro programa, opções, solução de erros.
- `docs/architecture.md` — camadas, ownership, threading, fila de eventos.
- `docs/backends.md` — Win32/X11: cobertura, limitações, XWayland.
- `docs/versioning.md` — SemVer e roadmap de releases.

## Roadmap (resumo)

v0.1.0 fundação (esta release) → v0.2.0 Display/Cursor → v0.3.0 texto/
clipboard/DnD → v0.4.0 Vulkan/OpenGL/Direct3D → v0.5.0 Wayland →
v0.6.0 gamepad/touch → v0.7.0 áudio → v0.8.0 ABI C → v1.0.0 estável.
Detalhes em `CHANGELOG.md` e `docs/versioning.md`.

## Licença

MIT — ver `LICENSE`. **Pendente de confirmação**: a especificação marca
a licença como "a definir"; MIT é o placeholder até decisão explícita.
