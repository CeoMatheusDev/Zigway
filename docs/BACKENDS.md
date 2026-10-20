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
`XScreenCount`/`XDisplayWidth`/`XDisplayHeight`) e notificações RandR
(`RRScreenChangeNotify`/`RRNotify` selecionados no root, emitindo
`display_change`). Posição usa
`_NET_MOVERESIZE_WINDOW` (EWMH, `StaticGravity`) quando o WM anuncia o
atom em `_NET_SUPPORTED`; sem WM/EWMH cai para `XMoveWindow`. A leitura
usa `XTranslateCoordinates` até o root e o evento `move` é emitido a
partir de `ConfigureNotify` quando a origem do cliente muda. Limites de
tamanho usam `XGetWMNormalHints`/`XSetWMNormalHints`
(`PMinSize`/`PMaxSize`) com round-trip de confirmação. Modos de vídeo
usam RandR: a lista vem de `XRRGetOutputInfo` (ids de modo do output) e
a troca usa `XRRSetCrtcConfig`, preservando posição, rotação e outputs do
CRTC, com readback do CRTC e reajuste do tamanho da tela
(`XRRSetScreenSize`) para envelopar os CRTCs ativos. Maximização usa
`_NET_WM_STATE_MAXIMIZED_HORZ`/`_VERT` via EWMH e confirma por
`PropertyNotify`; sem esse suporte, aplica geometria de fallback.
Fullscreen
usa `_NET_WM_STATE_FULLSCREEN` quando o WM anuncia os atoms EWMH;
`PropertyNotify` confirma o estado. Sem WM/EWMH, aplica
`XMoveResizeWindow` na tela X padrão e restaura a geometria anterior ao
sair (caminho síncrono).

Input bruto: `raw_key` traz o keycode do X11 (código do evdev + 8 no
Linux), que identifica a tecla física independentemente do layout; o
`Key` continua vindo do keysym (que distingue Shift/Control
esquerdo/direito).

Entrada de texto: o codepoint Unicode vem do keysym da tecla (nível 0,
ou nível 1 quando Shift esta pressionado), mapeado para ASCII/Latin-1/
keysyms Unicode. Não há input method: compose, dead keys e IME real
exigem um XIM e a libX11 local não cria input context (`XCreateIC`
falha), então esse suporte fica pendente.

Área de transferência: a plataforma cria uma janela oculta (1x1, nunca
mapeada) que possui a seleção `CLIPBOARD`; `setClipboardText` publica o
texto (UTF-8) e responde a `SelectionRequest` com `TARGETS`,
`UTF8_STRING`, `text/plain;charset=utf-8`, `text/plain` (em UTF-8) e
`STRING` (em Latin-1, caracteres fora do Latin-1 viram `?`) — assim
aplicativos legados conseguem ler o conteúdo (o `SelectionRequest` é
atendido no loop de eventos, ou seja, o aplicativo precisa bombear
eventos). A leitura é síncrona: `XConvertSelection` + espera pelo
`SelectionNotify` (até 500 ms), bombearando a conexão no intervalo
(eventos do app vão para a fila normal); os alvos são tentados em ordem
(`UTF8_STRING` → `text/plain;charset=utf-8` → `text/plain` → `STRING`) e
a resposta Latin-1 é convertida para UTF-8. A propriedade é lida em
blocos de 64 KB. `SelectionClear` (perda da posse) libera o texto
guardado.

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
- Fullscreen via EWMH é uma requisição: o WM pode ignorar; o evento
  `fullscreen` e `isFullscreen()` refletem o estado real. Sem EWMH, o
  fallback cobre a tela X padrão inteira (não escolhe o monitor da
  janela) e pode manter decoração se houver um WM sem EWMH.
- Limites de tamanho são uma requisição ao WM; ele pode ignorar ou
  ajustar. A gravação de `WM_NORMAL_HINTS` é confirmada, mas o
  cumprimento efetivo depende do WM. A mudança não força um resize
  imediato da janela atual.
- Maximização é uma requisição EWMH; sem suporte, o fallback cobre a
  tela X padrão inteira (não o monitor individual). Fullscreen e
  maximizado são mutuamente exclusivos.
- Área de transferência: alvos oferecidos = `TARGETS`, `UTF8_STRING`,
  `text/plain;charset=utf-8`, `text/plain` (UTF-8) e `STRING` (Latin-1,
  com `?` para o que não cabe). Alvos desconhecidos recebem recusa
  (`property = None`). A leitura bloqueia até 500 ms por alvo
  esperando o dono da seleção responder e cai para o próximo alvo se
  ele recusar. O texto publicado só é servido a outros aplicativos
  enquanto o evento `SelectionRequest` for atendido no loop de eventos.
- `setCursor` é validado por ausência de erro de protocolo; o efeito
  visual não é inspecionado pelo teste.
- Captura exige janela viewable (`GrabNotViewable` antes do mapeamento);
  o grab é liberado pelo servidor ao desmapear/destruir e o estado local
  acompanha. Não há confinamento do ponteiro (`confine_to = None`).
- Monitores: RandR 1.5+ é opcional em runtime. Sem `libXrandr.so.2`,
  sem a extensão, ou com versão <1.5, `displays()` reporta X screens
  (cada uma com origem `(0,0)`; são espaços independentes). Com RandR,
  apenas a tela padrão é consultada. Quando `libXrandr` expõe
  `XRRQueryExtension`/`XRRSelectInput`, screen/crtc/output notifications
  são selecionados no root e viram `display_change`; sem a biblioteca, o
  evento nativo não é emitido. Uma mudança pode gerar mais de um evento;
  reconsultar `displays()` é idempotente. `id` é o índice do snapshot
  (pode mudar em hotplug).
- Modos de vídeo: exigem RandR 1.5+ (monitores) e `libXrandr` em
  runtime; sem isso a lista é vazia e a troca retorna
  `DisplayModeUnsupported`. O layout de `XRROutputInfo` difere entre
  versões do Xrandr (`Connection`/`SubpixelOrder` de 2 ou 4 bytes) e é
  detectado em runtime, com validação contra os ids de modo do
  servidor. Aplica-se ao primeiro output/CRTC ativo do monitor: monitor
  sem CRTC ativo, com output desconectado ou com vários outputs tem
  comportamento limitado (apenas o primeiro output ativo). A taxa
  (`refresh_mhz`) é derivada de `dotClock` e dos totais de linha/coluna
  (aproximada). A troca não guarda o modo anterior: o aplicativo deve
  mantê-lo para poder voltar.
- XWayland conta como backend X11 (sem código Wayland nativo).

Validado com display real: `zig build test-x11` (inclui fullscreen e
maximização EWMH sob KWin, fallback sem WM em Xwayland aninhado,
round-trip de `WM_NORMAL_HINTS` e a enumeração de modos de vídeo).
A troca de modo de vídeo é validada pelo passo separado e destrutivo
`zig build test-x11-modes` (altera a resolução e restaura o modo
original), executado em Xwayland aninhado. Evento `display_change` e
mudança de resolução também validados manualmente em Xwayland; hotplug
físico não foi testado.

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
foco, `WM_CLOSE`→evento sem destruir, `WM_DISPLAYCHANGE`→
`display_change`, fullscreen sem borda (`WS_POPUP` + `SetWindowPos` no
monitor mais próximo, com restauração de estilo/retângulo), maximização
via `ShowWindow`/`IsZoomed` com eventos de `WM_SIZE`, limites de tamanho
via `WM_GETMINMAXINFO` (convertendo área de cliente para tracking size
com `AdjustWindowRectEx`), cursores do
sistema (`LoadCursorW` + `SetCursor` e `WM_SETCURSOR` por janela),
captura de mouse (`SetCapture`/`ReleaseCapture`/`GetCapture`, por
thread), enumeração de monitores
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
- `display_change` vem de `WM_DISPLAYCHANGE`; a mensagem só chega a
  janelas top-level (sem janelas abertas não há aviso) e hotplug pode
  ser reportado de forma best-effort pelo Windows.
- Fullscreen usa o monitor mais próximo via `MonitorFromWindow`; o estado
  é controlado pela API (mudanças externas de estilo não são detectadas).
  Sem validação em runtime (apenas compilação cruzada).
- Limites de tamanho são aplicados em `WM_GETMINMAXINFO` após converter
  a área de cliente para o tamanho externo com `AdjustWindowRectEx`; um
  máximo menor que o monitor também limita fullscreen. Sem validação em
  runtime (apenas compilação cruzada).
- Maximização usa `ShowWindow` e `IsZoomed`; mudanças externas de estado
  são refletidas por `WM_SIZE`. Fullscreen e maximizado são mutuamente
  exclusivos. Sem validação em runtime (apenas compilação cruzada).
- Captura de mouse é por thread: `SetCapture` pode falhar enquanto outra
  thread detém a captura (`PointerCaptureFailed`); a captura é liberada
  ao destruir a janela e verificada via `GetCapture`.
- Monitores usam `EnumDisplayMonitors`/`GetMonitorInfoW` (retângulo do
  monitor; `primary` vem de `MONITORINFOF_PRIMARY`). `id` é o índice do
  snapshot. Não há eventos de hotplug.
- Input bruto: `raw_key` traz o scan code (bits 16–23 do `lparam`),
  que identifica a tecla física (Shift esquerdo/direito, etc.).
- Entrada de texto: `WM_CHAR` (UTF-16) vira codepoint Unicode, com
  pares substitutos combinados; é por esse caminho que o IME confirma o
  texto composto. Sem validação em runtime (apenas compilação cruzada).
- Área de transferência: `OpenClipboard`/`EmptyClipboard`/
  `SetClipboardData` com `CF_UNICODETEXT` (UTF-16 convertido de UTF-8)
  e `GetClipboardData` na leitura. A área é aberta/fechada a cada
  operação; `GlobalAlloc`/`GlobalLock` para o bloco de memória. Sem
  validação em runtime (apenas compilação cruzada).
- Modos de vídeo: `EnumDisplaySettingsW` (por dispositivo
  `\\.\DISPLAY<n>`, via `MONITORINFOEXW`) e `ChangeDisplaySettingsExW`
  (troca dinâmica, sem gravar no registro). O `DisplayModeId` empacota
  largura, altura e o índice do modo, para recusar snapshots obsoletos.
  O Windows não sinaliza modo preferido e a frequência é inteira (Hz).
  A troca gera `WM_DISPLAYCHANGE`. Sem validação em runtime: apenas
  compilação cruzada e conferência dos layouts de `DEVMODEW`/
  `MONITORINFOEXW` contra os headers reais do Windows.

## Wayland (`src/platform/wayland/`)

Backend **nativo** do protocolo Wayland (não XWayland). A
libwayland-client é carregada em runtime (`dlopen`), como a libXrandr no
backend X11: sem dependência de link e, sem a biblioteca, o backend não
está disponível (`UnsupportedBackend`).

Cobertura (v0.5, em andamento): conexão com o compositor
(`wl_display_connect`), registry (`wl_display.get_registry` +
`wl_registry.bind`), outputs/monitores (`wl_output`: geometry, mode,
scale, name) expostos por `Platform.displays()`, seat
(`wl_seat.capabilities` → `Platform.seatCapabilities()`) e despacho
assíncrono sem bloquear (`prepare_read`/`read_events`/
`dispatch_pending`). As tabelas de interface são escritas à mão em Zig
(`protocol.zig`), conferidas contra o código gerado por
`wayland-scanner`.

Janelas (xdg-shell): `wl_surface` + `xdg_surface` + `xdg_toplevel`
criados pelo `wl_compositor`/`xdg_wm_base`, com título
(`xdg_toplevel.set_title`), app id, limites de tamanho
(`set_min_size`/`set_max_size`), maximização
(`set_maximized`/`unset_maximized`) e fullscreen
(`set_fullscreen`/`unset_fullscreen`, sem output: o compositor escolhe).
O cliente confirma cada `xdg_surface.configure` com `ack_configure` e
anexa um buffer `wl_shm` (pool por buffer, `memfd` + `mmap`, formato
XRGB8888 quando o compositor suporta) para mapear a superfície. O
`xdg_toplevel.configure` traz o tamanho aceito pelo compositor
(`0x0` = o cliente decide) e os estados (`maximized`/`fullscreen`),
publicados como eventos `resize`, `maximized` e `fullscreen`. O evento
`close` do `xdg_toplevel` vira o evento `close` da plataforma (o slot
segue ocupado até `destroyWindow`, como nos outros backends). O
`xdg_wm_base.ping` é respondido com `pong` (sem isso o compositor
considera o cliente travado). O `wl_shm.format` do compositor é lido
para escolher o formato do buffer. Esconder a janela usa o buffer nulo
(commit sem buffer), como manda o protocolo.

Ainda não implementado (retornam `NotImplemented`): input de teclado
(exige o keymap XKB), clipboard (`wl_data_device`) e modos de vídeo.
Também não há equivalente Wayland para `setSize` (o compositor decide
o tamanho), `setPosition` (a posição não é exposta ao cliente), `focus`
(o foco é do compositor) e cursor do sistema (exige `wl_pointer` e o
tema do compositor). A captura exclusiva de ponteiro também não existe
no protocolo base.

Ponteiro: o `wl_pointer` é criado quando o compositor anuncia a
capacidade no seat. `enter`/`leave`/`motion` viram `pointer_move`
(janela = a superfície sob o cursor, coordenadas da superfície),
`button` vira `pointer_button` (códigos Linux `BTN_LEFT`..`BTN_EXTRA`
mapeados para `left`/`right`/`middle`/`back`/`forward`) e `axis` vira
`scroll` (o valor em 120avos de grau tem precedência, depois os passos
discretos e, por fim, o valor bruto; a rolagem é publicada no `frame`
do compositor). As coordenadas `wl_fixed_t` (24.8) são convertidas
para pixels.

Limitações conhecidas:

- O buffer anexado é provisório (cor sólida): a superfície é mapeada e
  o ciclo de vida da janela funciona, mas a renderização real entra na
  fase de gráficos (v0.4).
- O tamanho do cliente é apenas uma sugestão: o compositor pode
  respondê-lo com outro no `configure` (e o evento `resize` traz o
  tamanho aceito).
- A escala do output (`wl_surface.preferred_buffer_scale`) ainda não é
  aplicada ao buffer.
- O primeiro `configure` também emite `resize` (o mapeamento é
  confirmado pelo compositor), mesmo sem mudança de tamanho.

Validado com compositor real: `zig build test-wayland` (KWin 6.7.5 em
Wayland nativo), incluindo o ciclo de vida de uma janela (criação,
`configure` confirmado com `resize`, troca de título, limites de
tamanho, maximização/fullscreen e destruição). Sem compositor, o teste
pula sem falhar. A CI não tem compositor Wayland: lá o passo apenas
exercita o caminho de "pula".

Detalhe: `wl_output` não informa qual output é o primário (exige
`xdg-output`), então `DisplayInfo.primary` é `false` no Wayland; o
tamanho reportado é o lógico (modo ÷ escala).

## null

Headless: sem recursos nativos; eventos via `injectEvent`; `setCursor`
é no-op e a captura de ponteiro é apenas estado interno (aceita todas as
variantes/janelas); `setPosition` atualiza o slot e emite `move`;
`displays()` retorna lista vazia (não inventa monitores),
`display_change` é testável via `injectEvent`, fullscreen e maximizado
são apenas estado lógico com eventos, e limites de tamanho são apenas
estado. Modos de vídeo: `displayModes` devolve lista vazia e
`setDisplayMode` retorna `DisplayModeUnsupported` (sem recursos nativos).
Entrada de texto e input bruto: sem teclado nativo (os eventos podem ser
injetados).
Área de transferência: texto guardado em memória, dentro da plataforma
(`setClipboardText`/`clipboardText` fazem round-trip). Usado pelos testes unitários e como fallback em SOs sem backend.
