# Roadmap — Zigway

Intenção de evolução, não compromisso de entrega nem declaração de
implementação. Versões seguem SemVer 2.0.0 (ver `VERSIONING.md`).

## v0.1.x — Fundação e estabilização (atual: v0.1.0-alpha.1)

- [x] Build Zig 0.17.0, Core, Platform multi-janelas
- [x] Window, Events (`union(enum)`), Input (teclado/mouse)
- [x] Backends Win32, X11, null/headless
- [x] Exemplos + testes unitários + live X11
- [x] CI (Linux/X11 + Windows) — `.github/workflows/ci.yml`
- [ ] Validação Win32 em runtime (requer Windows com desktop)
- [ ] Endurecimento de lifecycle e cobertura de regressão
- [ ] Beta → RC → `v0.1.0` (primeira funcional)

## v0.2.x — Display e Cursor

Monitores e modos de vídeo; cursores do SO e captura de ponteiro.

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
