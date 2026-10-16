# Zigway

**Native platform backend for game engines. Pure Zig.**

Zigway abstrai o sistema de janelas nativo (Win32, X11) para game
engines, frameworks GUI e aplicações nativas: janelas, eventos e input
com API Zig nativa, sem `@cImport`, sem headers C e sem dependências
externas. Versão atual: **0.1.0-alpha.1**. Exige **Zig 0.17.0**.

## Características

- **API Zig nativa** — error sets, `union(enum)` de eventos, tipos fortes.
- **Backends multiplataforma** — Win32, X11, null/headless; Wayland planejado.
- **Múltiplas janelas** por instância, sem estado global.
- **Handles geracionais** — ids expirados falham em vez de atingir outra janela.
- **Memória explícita** — alocador do chamador, fila de eventos sem alocação no hot path.
- **Headless** — backend null para testes e CI sem display.
- **Extensível** — pontos reservados para Vulkan/OpenGL/Direct3D (Fase 4) e ABI C (Fase 8).

## Compatibilidade

| Plataforma | Backend | Compilação | Runtime |
|---|---|---|---|
| Linux | X11 | validado | validado com display real |
| Windows | Win32 | cross-compilação validada | **pendente** (sem Windows disponível) |
| Qualquer | null/headless | validado | validado (testes unitários) |
| Linux | Wayland | planejado (v0.5.0) | não implementado |

X11 exige `libX11` do sistema + headers em build (dependência de
sistema documentada, não pacote Zig). Execução via XWayland conta como
backend X11.

## Requisitos

- Zig **0.17.0** (`zig version` deve imprimir `0.17.0`).
- Linux/X11: `libX11-devel` (Fedora) ou `libx11-dev` (Debian/Ubuntu).
- Windows: SDK padrão.

## Compilar, testar, exemplificar

```bash
zig build              # biblioteca
zig build test         # unitários headless (sem display)
zig build test-x11     # integração X11 (pula sem display; Xvfb no CI)
zig build examples     # hello_window, multiple_windows, keyboard_input
zig fmt --check .      # formatação
```

Seleção de backend no build (padrão do `Options.backend == .auto`):

```bash
zig build -Dplatform=x11            # Linux
zig build -Dplatform=win32          # Windows (alvo Windows)
zig build -Dplatform=null_backend   # headless
```

Compilação cruzada:

```bash
zig build -Dtarget=x86_64-windows -Dplatform=win32
```

Ver `docs/BUILDING.md` para detalhes e solução de erros.

## Exemplo

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

## Usar como dependência

Via caminho local (`build.zig.zon` do consumidor):

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

Fetch remoto (`zig fetch` de tag publicada): pendente da primeira
release publicada no GitHub. Não há tarball oficial ainda.

## Roadmap

- **Implementado (v0.1.0-alpha.1):** fundação, janelas, eventos, input, Win32+X11+null.
- **Em desenvolvimento:** estabilização da Fase 1, CI, validação Win32 em runtime.
- **Planejado:** Display/Cursor (v0.2.x), texto/clipboard (v0.3.x), gráficos (v0.4.x), Wayland (v0.5.x), expansões de input (v0.6.x), estabilização (v0.7.x), ABI C (v0.8.x), 1.0 estável. Ver `docs/ROADMAP.md`.

## Documentação

- `docs/BUILDING.md` — requisitos, build, testes, cross, backends.
- `docs/ARCHITECTURE.md` — camadas, ownership, handles, threading.
- `docs/API.md` — referência da API pública.
- `docs/BACKENDS.md` — cobertura e limitações por backend.
- `docs/ROADMAP.md` — versões planejadas.
- `docs/GRAPHICS.md` — integração gráfica planejada (sem renderer próprio).
- `docs/VERSIONING.md` — SemVer e releases.
- `CHANGELOG.md` — histórico de mudanças.

## Contribuir

Ver `CONTRIBUTING.md`. Commits em Conventional Commits; toda mudança
atualiza `CHANGELOG.md` (`## [Não lançado]`); nenhum teste declarado
sem execução; nenhuma publicação remota sem autorização.

## Licença

MIT — ver `LICENSE`. Copyright (c) 2026 CeoMatheusDev.
