# Roadmap — Zigway

Intenção de evolução, não compromisso de entrega nem declaração de
implementação. Versões seguem SemVer 2.0.0 (ver `VERSIONING.md`).

**Foco do projeto:** camada de plataforma do SO — janelas, backends,
input bruto, área de transferência (clipboard), cursor, displays e
entrada de texto/IME. Não há renderer, dispositivo gráfico ou pipeline
próprio: a integração com GPU entra como extensão de plataforma (ver
`GRAPHICS.md`).

## v0.1.x — Fundação e estabilização (atual: v0.1.0-alpha.2)

- [x] Build Zig 0.17.0, Core, Platform multi-janelas
- [x] Window, Events (`union(enum)`), Input (teclado/mouse)
- [x] Backends Win32, X11, null/headless
- [x] Exemplos + testes unitários + live X11
- [x] CI (Linux/X11 + Windows) — `.github/workflows/ci.yml`
- [ ] Validação Win32 em runtime (requer Windows com desktop)
- [x] Endurecimento de lifecycle e cobertura de regressão
- [ ] Beta → RC → `v0.1.0` (primeira funcional)

## v0.2.x — Display e Cursor

Cursores do SO, captura de ponteiro, enumeração de monitores, posição,
fullscreen, maximização, modos de vídeo e limites de tamanho de janela
implementados (`Window.setCursor`/`capturePointer`/`setPosition`/
`setFullscreen`/`setMaximized`/`setSizeLimits`, `Platform.displays`/
`displayModes`/`setDisplayMode` e eventos
`display_change`/`fullscreen`/`maximized`). No X11, monitores físicos usam
RandR 1.5+ via `libXrandr` opcional em runtime, com fallback para X
screens, e posição usa EWMH (`_NET_MOVERESIZE_WINDOW`) quando
disponível; Win32 usa `EnumDisplayMonitors` e
`SetWindowPos`/`WM_MOVE`; null retorna lista vazia e aplica posição
localmente. Notificações de mudança de display usam RandR no X11 e
`WM_DISPLAYCHANGE` no Win32. Fullscreen e maximização usam
EWMH/`_NET_WM_STATE` no X11 (com fallback de geometria); fullscreen usa
`WS_POPUP` e maximização `ShowWindow` no Win32; limites de tamanho usam
`WM_NORMAL_HINTS` no X11 e `WM_GETMINMAXINFO` no Win32. Modos de vídeo
usam RandR no X11 (`XRRSetCrtcConfig`, com readback e reajuste do
tamanho da tela); no Win32 e no backend null a troca permanece pendente
(lista vazia / `DisplayModeUnsupported`).

## v0.3.x — Text Input e Clipboard

Unicode/IME separado de `Key`; área de transferência; drag & drop.

## v0.4.x — Graphics Integration

Extensões e superfícies Vulkan; contextos OpenGL (WGL/GLX/EGL);
handles DXGI/Direct3D. Sem renderer próprio (ver `GRAPHICS.md`).

## v0.5.x — Wayland

Connection, registry, surfaces, seat, outputs, despacho assíncrono.

## v0.6.x — Expansões de input

Gamepad, touch, tablet (canetas), power (inibir suspensão).

## v0.7.x — Estabilização de API

Congelar contratos públicos a partir do uso real das fases anteriores.

## v0.8.x — ABI C opcional

Camada isolada: opaque handles, result codes, header público, testes
de ABI. Nunca remodela a API Zig.

## v0.9.x — Preparação para 1.0

Otimização, auditoria de memória, documentação final.

## v1.0.0 — Release estável

API congelada; breaking changes só em MAJOR.
