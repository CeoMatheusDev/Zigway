# Backends — cobertura e limitações (v0.1.0-alpha.2)

## X11 (`src/platform/x11/`)

ABI Xlib declarada manualmente (`api.zig`), layouts conferidos contra o
header do sistema. Link dinâmico com `libX11.so` (dependência de sistema
documentada — não é pacote Zig, não usa `@cImport`). `libXrandr.so.2` é
opcional em runtime para monitores físicos (RandR 1.5+), carregada via
`dlopen`; não é dependência de link nem exige headers no build.

Cobertura: abrir/fechar display, criar/destruir, mapear/desmapear,
título, resize, posição da área de cliente, foco, `WM_DELETE_WINDOW`
(close, com checagem de `WM_PROTOCOLS`), teclado via `XLookupKeysym`,
mouse (movimento,
5 botões, roda vertical/horizontal), modificadores
(Shift/Ctrl/Alt/Super), multi-janelas, cursores do sistema
(`XCreateFontCursor` + `XDefineCursor`, cache por backend liberado no
`deinit`), captura de ponteiro (`XGrabPointer`/`XUngrabPointer`,
exclusiva por conexão, com transferência entre janelas) e enumeração
de monitores (`XRRGetMonitors`, RandR 1.5+, com fallback para
`XScreenCount`/`XDisplayWidth`/`XDisplayHeight`). Posição usa
`_NET_MOVERESIZE_WINDOW` (EWMH, `StaticGravity`) quando o WM anuncia o
atom em `_NET_SUPPORTED`; sem WM/EWMH cai para `XMoveWindow`. A leitura
usa `XTranslateCoordinates` até o root e o evento `move` é emitido a
partir de `ConfigureNotify` quando a origem do cliente muda.

Teclado numérico: mesmas teclas lógicas do Win32 — com NumLock,
`n0-n9` e `enter`; sem NumLock, navegação (`home`, setas,
`page_up`/`page_down`, `insert`, `delete`, `end`). Operadores
(`+`, `*`, `/`) seguem `.unknown` nos dois backends, pois `Key` não
possui variantes para eles.

Auto-repeat: `Platform.init(.x11)` habilita *detectable autorepeat*
(XKB, `XkbSetDetectableAutoRepeat` — parte da Xlib). O servidor passa a
enviar apenas `KeyPress` repetidos, sem `KeyRelease` intermediário, e o
backend marca `repeat=true` quando uma tecla mapeada já está
pressionada. Servidores sem suporte retornam `supported=false`; nesse
caso `repeat` permanece `false` (comportamento anterior, sem quebrar o
estado da tecla). `Key.unknown` nunca é marcado como repetição, pois
agrupa teclas distintas não mapeadas.

Destruição externa (servidor/WM mata a janela): o backend marca
`should_close`, emite `close` uma vez e remove a entrada nativa —
operações seguintes retornam `InvalidWindow` em vez de atingir XID
morta (o handler padrão de erros X encerra o processo em `BadWindow`).
O slot segue ocupado até `destroyWindow` do consumidor.

Erros de protocolo X: `Platform.init(.x11)` instala um handler de erro
(`XSetErrorHandler`) que ignora erros recuperáveis, em vez do handler
padrão da Xlib (que encerra o processo). Isso cobre a corrida entre uma
requisição assíncrona e uma janela destruída pelo servidor antes do
`poll`. O handler é global ao processo (limitação da Xlib) e permanece
instalado após `deinit`; não tem estado próprio.

Limitações conhecidas:

- Mapeamento keysym→`Key` cobre o conjunto documentado; o restante é
  `.unknown` (não falha).
- `focus()` usa `XSetInputFocus` (melhor esforço; o WM pode recusar).
- Posição: é uma requisição ao WM, que pode ajustar, restringir ou
  ignorar (especialmente antes do mapeamento); a confirmação chega via
  `move`. `XMoveWindow` sem EWMH pode aplicar offsets de decoração.
- `setCursor` é validado por ausência de erro de protocolo; o efeito
  visual não é inspecionado pelo teste.
- Captura exige janela viewable (`GrabNotViewable` antes do mapeamento);
  o grab é liberado pelo servidor ao desmapear/destruir e o estado local
  acompanha. Não há confinamento do ponteiro (`confine_to = None`).
- Monitores: RandR 1.5+ é opcional em runtime. Sem `libXrandr.so.2`,
  sem a extensão, ou com versão <1.5, `displays()` reporta X screens
  (cada uma com origem `(0,0)`; são espaços independentes). Com RandR,
  apenas a tela padrão é consultada. Não há eventos de hotplug: cada
  chamada reflete o estado no momento. Troca de modo de vídeo não é
  implementada; `id` é o índice do snapshot (pode mudar em hotplug).
- XWayland conta como backend X11 (sem código Wayland nativo).

Validado com display real: `zig build test-x11`.

## Win32 (`src/platform/win32/`)

ABI user32/kernel32/gdi32 declarada manualmente (`api.zig`, layouts
para 64-bit). Sem link com CRT além do necessário.

Cobertura: registro de classe (nome único por instância, permitindo
múltiplas `Platform` no mesmo processo), `CreateWindowExW` (área de cliente
ajustada via `AdjustWindowRectEx`), `WndProc` + pump com `PeekMessageW`,
teclado (VK→`Key`, flag `repeat` via bit 30), modificadores derivados do
estado autoritativo via `GetKeyState` (mouse e teclado), mouse
(movimento, 5 botões, wheel vertical/horizontal), `WM_SIZE` (inclui
minimize como invisível), posição via `WM_MOVE` + `ClientToScreen`,
`GetWindowRect`/`SetWindowPos` preservando o delta da área de cliente,
foco, `WM_CLOSE`→evento sem destruir,
cursores do sistema (`LoadCursorW` + `SetCursor` e `WM_SETCURSOR` por
janela), captura de mouse (`SetCapture`/`ReleaseCapture`/`GetCapture`,
por thread), enumeração de monitores
(`EnumDisplayMonitors`/`GetMonitorInfoW`), multi-janelas.

Destruição externa: como no X11, a entrada nativa é removida e
operações seguintes retornam `InvalidWindow`; o slot segue ocupado
até `destroyWindow` do consumidor.

Limitações conhecidas:

- Sem validação em runtime ainda (validado por compilação cruzada
  `x86_64-windows`; sem máquina Windows disponível).
- Numpad 0–9 mapeados para `n0`–`n9` (mesma tecla lógica do X11;
  `Key` não distingue numpad da linha superior).
- No `WM_KEYDOWN` o `wparam` traz o VK genérico (ex.: `VK_SHIFT`), sem
  distinguir lado: `VK_SHIFT`/`VK_LSHIFT`/`VK_RSHIFT` viram
  `left_shift`, e o mesmo para Ctrl/Alt/Super. O X11 distingue
  esquerda/direita. Distinguir no Win32 exigiria o scancode
  (`lparam` bits 16–23) — fora do escopo desta fase. Isso afeta apenas
  o valor de `Key` e de `key_up`, não o estado dos `modifiers` (que vem
  de `GetKeyState`, autoritativo).
- `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` entregam coordenadas de tela, mas
  `ScrollEvent` não carrega coordenadas nesta fase; não há conversão
  (`ScreenToClient`).
- `focus()` usa `SetFocus` (melhor esforço; foreground pertence ao SO).
- Posição é a origem da área de cliente; o WM pode ajustar/clamp a
  janela. `setPosition` consulta a posição real após `SetWindowPos` e
  emite `move`; movimentos do usuário chegam por `WM_MOVE`. Sem
  validação em runtime (apenas compilação cruzada).
- Captura de mouse é por thread: `SetCapture` pode falhar enquanto outra
  thread detém a captura (`PointerCaptureFailed`); a captura é liberada
  ao destruir a janela e verificada via `GetCapture`.
- Monitores usam `EnumDisplayMonitors`/`GetMonitorInfoW` (retângulo do
  monitor; `primary` vem de `MONITORINFOF_PRIMARY`). `id` é o índice do
  snapshot. Não há troca de modo de vídeo nem eventos de hotplug.

## Wayland

Não implementado. Ver `src/platform/wayland/README.md`.

## null

Headless: sem recursos nativos; eventos via `injectEvent`; `setCursor`
é no-op e a captura de ponteiro é apenas estado interno (aceita todas as
variantes/janelas); `setPosition` atualiza o slot e emite `move`;
`displays()` retorna lista vazia (não inventa monitores). Usado pelos
testes unitários e como fallback em SOs sem
backend.
