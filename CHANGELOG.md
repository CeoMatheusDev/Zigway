# Changelog — Zigway

Formato baseado em Keep a Changelog; versionamento SemVer 2.0.0
(ver `docs/versioning.md`).

## [0.1.0-alpha.1] — 2026-10-15

Primeira etapa validável: fundação, build e API inicial (Fase 1 parcial).

### Adicionado

- Build system Zig 0.17.0 com `-Dplatform=auto|win32|x11|null`
  (`wayland` rejeitado com erro claro; seleções incompatíveis com o
  alvo também falham no build).
- Core: tipos (`Key`, `MouseButton`, `Modifiers`, ids), errors, handles
  geracionais, capabilities (compilação vs. runtime), versão.
- `Platform`: init/deinit, multi-janelas, `pollEvents`/`nextEvent`,
  `injectEvent`, estado de input centralizado, cleanup de falhas
  parciais, poda de eventos de janelas destruídas.
- `Window`: create/destroy, título, resize, visibilidade, foco,
  close request, estado.
- Eventos: `union(enum)` (close, resize, focus, key, pointer, scroll),
  fila com capacidade fixa, coalescing de pointer_move, preservação de
  eventos críticos (`close`) em overflow com contador `dropped`.
- Input: teclado (físico/lógico via `Key`), botões, movimento, scroll
  vertical/horizontal, modificadores; estado consistente com a fila.
- Backend X11 sobre Xlib com ABI manual (sem `@cImport`): janelas,
  WM_DELETE_WINDOW, teclado (keysym→Key), mouse, resize, foco,
  multi-janelas.
- Backend Win32 com ABI manual: classe, `WndProc`, message pump,
  teclado (VK→Key, repeat), mouse, wheel, resize, foco, multi-janelas.
- Backend null (headless) para testes e fallback.
- Exemplos: `hello_window`, `multiple_windows`, `keyboard_input`.
- Testes unitários headless (core, fila, input, registry, backends
  puros, lifecycle) + teste live X11 (`zig build test-x11`).
- Docs: architecture, getting-started, backends, versioning.

### Validação

- `zig build`, `zig build test` (todos passam), `zig build examples`.
- `zig build test-x11`: passa com display real.
- Win32: compilação cruzada `x86_64-windows` (runtime pendente).

### Limitações conhecidas

- Win32 sem validação em runtime (sem Windows disponível).
- X11: auto-repeat reportado como `key_down` sem flag `repeat`.
- X11: sem detecção de layout de teclado além do mapeamento atual.
- Sem Display/Cursor (v0.2.0), texto/IME/clipboard (v0.3.0), gráficos
  (v0.4.0), Wayland (v0.5.0), ABI C (v0.8.0).

## Roadmap

- v0.1.0-alpha.2 — window lifecycle hardening + CI.
- v0.1.0-beta.1 — Win32 e X11 funcionais com validação em Windows real.
- v0.1.0-beta.2 — input e eventos completos.
- v0.1.0-rc.1 — testes e estabilização. v0.1.0 — primeira funcional.
- v0.2.0 Display/Cursor · v0.3.0 texto/clipboard/DnD · v0.4.0
  Vulkan/OpenGL/Direct3D · v0.5.0 Wayland · v0.6.0 gamepad/touch/tablet
  · v0.7.0 áudio · v0.8.0 ABI C · v0.9.0 otimização · v1.0.0 estável.
