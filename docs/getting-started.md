# Getting Started — Zigway

## Pré-requisitos

```bash
zig version   # deve imprimir 0.17.0
```

Linux (X11): headers e lib de desenvolvimento:

```bash
# Fedora
sudo dnf install libX11-devel
# Debian/Ubuntu
sudo apt install libx11-dev
```

Windows: apenas o SDK padrão (nada a instalar além do Zig).

## Primeiro programa

```zig
const zigway = @import("zigway");

var platform = try zigway.Platform.init(allocator, .{});
defer platform.deinit();

var window = try platform.createWindow(.{
    .width = 1280,
    .height = 720,
    .title = "Meu jogo",
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
}
```

## Opções de Platform

```zig
try zigway.Platform.init(allocator, .{
    .backend = .auto,            // auto | x11 | win32 | null_backend
    .event_queue_capacity = 256, // > 0
});
```

`.wayland` retorna `error.NotImplemented`. Backend de outro SO retorna
`error.UnsupportedBackend`. Sem display (`DISPLAY` ausente no Linux),
o backend X11 retorna `error.NoDisplay` — use `.null_backend` para
lógica headless/testes.

## Comandos

```bash
zig build               # compila a biblioteca
zig build test          # unitários headless (sempre verdes sem display)
zig build test-x11      # live X11 (pula sem display)
zig build examples      # compila os 3 exemplos
./zig-out/bin/hello_window
```

## Erros comuns

| Sintoma | Causa provável |
|---|---|
| `error.NoDisplay` | sem servidor X / `DISPLAY` não definido |
| `error.UnsupportedBackend` | `.win32` em Linux ou `.x11` em Windows |
| `error.InvalidConfig` | dimensão 0, título > 1024 bytes, capacidade 0 |
| `error.InvalidWindow` | id expirado ou de outra instância |
| falha em `-Dplatform=wayland` | esperado: ainda não implementado |
