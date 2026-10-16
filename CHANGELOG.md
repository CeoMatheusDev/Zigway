# Changelog — Zigway

Formato baseado em Keep a Changelog; versionamento SemVer 2.0.0
(ver `docs/VERSIONING.md`).

## [Não lançado]

### Corrigido

- `Platform.deinit` idempotente + guards pós-deinit (`PlatformClosed`,
  no-ops e falhas seguras em vez de use-after-free/double-free).
- Perda de foco libera teclas/botões pressionados com eventos
  sintéticos (`input.releaseAll` no `FocusOut`/`WM_KILLFOCUS`):
  nada fica preso após Alt+Tab.
- Win32 zera os modificadores incrementais no `WM_KILLFOCUS`: antes,
  um Alt/Super segurado no Alt+Tab permanecia ativo nos eventos
  seguintes (o `wparam` do mouse só recobre shift/control).
- Win32 registra classe de janela com nome único por instância
  (`ZigwayWindow#N`): múltiplas `Platform` coexistem no processo.
- Destruição externa de janela (servidor/WM no X11, `WM_DESTROY`
  externo no Win32) agora remove a entrada nativa do backend: marca
  `should_close`, emite `close` uma vez e operações seguintes
  retornam `InvalidWindow`. Antes, chamadas atingiam handles mortos
  (no X11, `BadWindow` encerra o processo no handler padrão).
- `ClientMessage` no X11 agora exige `message_type == WM_PROTOCOLS`
  antes de aceitar `WM_DELETE_WINDOW` (evita `close` espúrio de
  mensagens alheias).
- `Platform.setWindowSize` não atualiza mais o slot otimisticamente:
  o slot reflete o último tamanho confirmado (via evento nativo ou
  backend síncrono); antes, o `ConfigureNotify` do X11 era engolido e
  nenhum evento `resize` era emitido.
- `Platform.destroyWindow` limpa a referência de ponteiro do estado de
  input (`pointer_window`) quando ela aponta para a janela destruída:
  antes o estado mantinha um id morto após o destroy.
- X11 instala um handler de erro (`XSetErrorHandler`) que ignora erros
  de protocolo recuperáveis: antes, um `BadWindow` de uma requisição
  assíncrona (janela destruída pelo servidor antes do `poll`) encerrava
  o processo pelo handler padrão da Xlib.

### Adicionado

- `Event.window()`: janela associada ao evento, quando houver
  (usado pela poda de eventos de janelas destruídas).
- Cobertura de regressão: reuso de slot/geração no nível Platform,
  destroy durante o consumo, poda mista, deinit com janelas vivas,
  cópia + double-deinit, falha de alocação em `createWindow`, stress
  de 32 janelas, `InvalidWindow` em ops sobre id morto, ordenação de
  overflow, transições de botões/modificadores/scroll, limpeza de
  `pointer_window` no destroy e consistência do estado de input sob
  descarte por overflow.
- Teste de sincronia de versão (`version string matches build.zig.zon`):
  falha ruidosamente se `src/core/version.zig` divergir de
  `build.zig.zon` (declarado como entrada do passo de teste).
- `docs/API.md`: referência da API pública real.
- `docs/ROADMAP.md`: intenção de evolução por versão.
- `docs/GRAPHICS.md`: contrato da integração gráfica planejada
  (sem renderer próprio; nada implementado).

### Alterado

- Documentação em `docs/` com nomes em maiúsculas (`ARCHITECTURE.md`,
  `BUILDING.md`, `BACKENDS.md`, `VERSIONING.md`); `getting-started.md`
  virou `BUILDING.md` com conteúdo de build/testes/cross.
- Exemplos movidos para `examples/` (antes `examples/zig/`), sem
  mudança de nomes ou comportamento.
- `tests/live_x11.zig` pula (em vez de falhar) quando o backend X11
  está indisponível no alvo (`UnsupportedBackend`/`NotImplemented`).

## [0.1.0-alpha.1] — 2026-10-15

Primeira etapa validável: fundação, build e API inicial (Fase 1 parcial).

### Adicionado

- Build system Zig 0.17.0 com `-Dplatform=auto|win32|x11|null_backend`
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
