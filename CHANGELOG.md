# Changelog — Zigway

Formato baseado em Keep a Changelog; versionamento SemVer 2.0.0
(ver `docs/VERSIONING.md`).

## [Não lançado]

### Adicionado

- **Métricas do loop de eventos**: novo exemplo `bench_loop`
  (latência de `wakeup`, custo de `poll` e de `waitEvents(0)`), com a
  metodologia documentada em `docs/BUILDING.md`.
- **Escala e DPI (sistema generico)**: novo tipo `Scale` (fracao
  `numerator/denominator`), `Window.scale()`, `Window.bufferSize()`
  (tamanho fisico do buffer) e `Platform.displayScale()`, com o evento
  `scale_changed`. As unidades ficam explicitas: tamanho logico
  (unidades de superficie) x escala = tamanho fisico do buffer.
  No Wayland: `wp_fractional_scale_manager_v1` + `wp_viewporter` (escala
  fracionaria, buffer escalado e viewport com origem fisica e destino
  logico); no Win32: `SetProcessDpiAwarenessContext` (per monitor aware
  v2), `GetDpiForWindow`/`GetDpiForMonitor` e `WM_DPICHANGED` (muda a
  escala e aplica o retangulo sugerido); no X11: aproximacao pelo DPI
  da tela (o X11 nao tem escala por monitor).
- **Contexto textual para o IME**: `Window.setSurroundingText(text,
  cursor)` repassa o contexto ao compositor (a plataforma nao guarda o
  texto) e o evento `surrounding_delete` (`{ window, before, after }`)
  avisa o pedido de delecao do IME (a decisao de apagar e da
  aplicacao).
- **Entrada de texto/IME no Wayland** (`zwp_text_input_v3`): o
  compositor anuncia `zwp_text_input_manager_v3`; o `zwp_text_input_v3`
  habilita a entrada na superfície focada, publica o texto em composição
  (preedit) e o texto confirmado. Eventos novos na API: `composition_start`
  e `composition_end`; o preedit é consultado com
  `Platform.compositionText(id)` (buffer da plataforma, sem alocação por
  evento).
- **Ciclo de eventos com espera e wakeup**: `Platform.waitEvents(timeout_ms)`
  (negativo = espera indefinida) e `Platform.wakeup()` para acordar de
  outra thread. No X11 e no Wayland a espera usa o descritor nativo
  junto com um self-pipe; no Win32, `MsgWaitForMultipleObjects` com um
  evento do kernel. Sem busy-wait.
- **API de capacidades**: `Platform.capabilities()` informa o que o
  backend suporta (posicionamento absoluto, resize/foco pedidos,
  clipboard, IME, cursor do sistema, captura de ponteiro, escala
  fracionária, modos de vídeo, seat) para a aplicação não precisar
  identificar o backend.

### Corrigido

- **Wayland: `wp_viewport.set_source` invalido**: usava (-1,-1) com
  tamanho valido, o que o protocolo rejeita (`bad_value`); a origem do
  viewport e (0,0) com o tamanho do buffer.
- **`wakeup` apos o teardown**: o self-pipe e marcado como fechado antes
  de fechar os descritores, para que um `signal` concorrente nao
  escreva num descritor reciclado.
- **Wayland: ordem de destruição**: `wl_display_disconnect` acontecia
  antes de destruir a superfície e o tema do cursor (e de outros
  objetos do protocolo), o que usava proxies depois da conexão morta e
  causava *segfault* no `wl_cursor_theme_destroy`. O teardown agora
  segue a ordem de dependência (janelas → cursor → globals → registry →
  conexão) e libera proxies que eram vazados (`wl_shm`, `wl_compositor`,
  `xdg_wm_base`, `wl_pointer`, `wl_keyboard`).
- **Wayland: cursor do sistema**: `setCursor` passou a usar o tema real
  do compositor (`libwayland-cursor`) com uma superfície dedicada.

## [0.1.0-alpha.3] — 2026-10-20

Terceira etapa: display (monitores, modos de vídeo), texto/clipboard
com separação do input bruto de tecla e **backend Wayland nativo**
(conexão, outputs, seat, janelas xdg-shell, ponteiro, teclado e
clipboard). Validado com display real no X11 e no Wayland (KWin nativo).

### Adicionado

- **Entrada de teclado no backend Wayland**: o `wl_keyboard` e criado
  quando o compositor anuncia a capacidade no seat. O `keymap` XKB
  (formato texto, entregue por um descritor) e interpretado pela
  **libxkbcommon**, carregada em runtime (`dlopen`), como a
  libwayland: sem ela o teclado nao entrega teclas e o resto do
  backend continua funcionando. O keycode vira keysym (com layout e
  modificadores) e depois na tecla logica da API; `enter`/`leave`
  viram `focus` (a perda de foco libera as teclas pressionadas) e
  `key` vira `key_down`/`key_up` com os modificadores do evento
  `modifiers` do compositor.- `src/platform/keysym.zig`: modulo compartilhado com o mapeamento
  keysym (X11/XKB) -> tecla logica, antes duplicado no backend X11.
  O backend X11 passou a usa-lo (sem mudanca de comportamento).
- `raw_key` no backend Wayland: o keycode XKB (evdev + 8, como o
  keycode do X11) identifica a tecla fisica, independente do layout.- **Entrada de ponteiro no backend Wayland**: o `wl_pointer` e criado
  quando o compositor anuncia a capacidade no seat. `enter`/`leave`/
  `motion` viram `pointer_move` (com a janela da superficie e as
  coordenadas em pixels, convertidas de `wl_fixed_t`), `button` vira
  `pointer_button` (codigos Linux `BTN_LEFT`..`BTN_EXTRA` mapeados para
  `left`/`right`/`middle`/`back`/`forward`) e `axis` vira `scroll`
  (valor em 120avos de grau tem precedencia, depois os passos discretos
  e, por fim, o valor bruto; publicado no `frame` do compositor).
  Cobertura unitaria do mapeamento e live (o `wl_pointer.enter`
  identifica a janela sob o cursor).
- **Janelas no backend Wayland nativo** (xdg-shell): `createWindow`
  cria `wl_surface` + `xdg_surface` + `xdg_toplevel` via
  `wl_compositor`/`xdg_wm_base`, com titulo (`xdg_toplevel.set_title`),
  app id, limites de tamanho (`set_min_size`/`set_max_size`),
  maximizacao (`set_maximized`/`unset_maximized`) e fullscreen
  (`set_fullscreen`/`unset_fullscreen`, o compositor escolhe o output).
  O `xdg_surface.configure` e confirmado com `ack_configure` e o cliente
  anexa um buffer `wl_shm` (pool + buffer por janela, `memfd` + `mmap`,
  formato escolhido entre os suportados pelo compositor) para mapear a
  superficie. Eventos: `resize` (tamanho aceito pelo compositor),
  `maximized`, `fullscreen` e `close` (o slot segue ocupado ate
  `destroyWindow`, como nos demais backends). `xdg_wm_base.ping` e
  respondido com `pong`. Esconder a janela usa o buffer nulo (commit sem
  buffer), como manda o protocolo.
- Tabelas de interface do xdg-shell em Zig
  (`src/platform/wayland/protocol.zig`): `xdg_wm_base`, `xdg_surface`,
  `xdg_toplevel`, `xdg_popup` e `xdg_positioner`, conferidas contra o
  codigo gerado por `wayland-scanner` (assinaturas, indices de request
  e tabelas de argumentos, que definem a validacao de tipos no
  demarshal dos eventos).
- Cobertura live Wayland: criacao de janela com `configure` confirmado
  (evento `resize`), troca de titulo, limites de tamanho,
  maximizacao/fullscreen e destruicao, sem quebrar a conexao.

### Corrigido

- Tabelas de argumentos do protocolo base Wayland: `wl_surface.enter`
  /`leave` recebem um `wl_output` (antes apontavam para `wl_surface`),
  `wl_surface.attach` recebe um `wl_buffer`, e `wl_pointer`/`wl_keyboard`
  declaram a `wl_surface` de `enter`/`leave`/`set_cursor`. A tabela
  incorreta fazia o compositor reportar "invalid object" ao entrar na
  janela.
- Ordem do `configure` no backend Wayland: o `ack_configure` e o
  `commit` com buffer sao separados (o `ack` assim que o serial chega,
  o buffer quando o tamanho do `xdg_toplevel.configure` e conhecido).
  Anexar buffer antes do `ack` (ou com tamanho diferente do aceito)
  fazia o compositor encerrar a conexao ("unconfigured_buffer" /
  "invalid_size").
- `xdg_wm_base` sem listener: o `ping` do compositor era descartado
  (sem `pong` o compositor considera o cliente travado e encerra a
  conexao). O listener foi registrado no bind do `xdg_wm_base`.
- `Window.setCursor(Cursor)` / `Platform.setWindowCursor`: cursores do
  sistema por janela (`default`, `text`, `crosshair`, `hand`,
  `resize_horizontal`, `resize_vertical`, `resize_all`, `not_allowed`,
  `wait`). X11 usa `XCreateFontCursor`/`XDefineCursor` com cache por
  backend liberado no `deinit`; Win32 usa `LoadCursorW`/`SetCursor` e
  trata `WM_SETCURSOR` por janela; null aceita como no-op. Falha de
  criacao/aplicacao retorna `CursorCreationFailed`.
- Cobertura live X11: todas as variantes sao criadas/aplicadas e
  reaplicadas (cache), contando erros de protocolo da conexao.
- `Window.capturePointer`/`releasePointer` e
  `Platform.captureWindowPointer`/`releaseWindowPointer`: captura de
  ponteiro exclusiva por `Platform`, com transferencia ao capturar
  outra janela. X11 usa `XGrabPointer`/`XUngrabPointer` (grab liberado
  ao desmapear/destruir); Win32 usa `SetCapture`/`ReleaseCapture` e
  verifica `GetCapture`; null mantem estado interno. Falha de
  aquisicao retorna `PointerCaptureFailed`; a liberacao e idempotente e
  infalivel.
- Cobertura live X11: captura bloqueia grab de outra conexao, transfere
  entre janelas e libera o grab ao soltar a detentora.
- `Platform.displays(allocator) ![]DisplayInfo`: snapshot dos
  monitores/display outputs, com `DisplayId.eql`/`isValid`. X11 usa
  RandR 1.5+ via `libXrandr` carregada dinamicamente em runtime
  (opcional, sem dependencia de link) e cai para X screens quando a
  biblioteca/extensao nao esta disponivel; Win32 usa
  `EnumDisplayMonitors`/`GetMonitorInfoW`; null retorna lista vazia
  (nao inventa monitores). Cobertura live X11 valida geometria e IDs.
  Troca de modo de video permanece fora desta fase.
- `Window.setPosition`/`position` e
  `Platform.setWindowPosition`/`windowPosition`, com evento `move`
  (`MoveEvent`). A posicao e a origem da area de cliente em
  coordenadas de tela. X11 usa `_NET_MOVERESIZE_WINDOW` com
  `StaticGravity` quando o WM anuncia o atom em `_NET_SUPPORTED` e cai
  para `XMoveWindow` sem WM/EWMH; a confirmacao chega via
  `ConfigureNotify`. Win32 usa `SetWindowPos` preservando o delta da
  area de cliente e `WM_MOVE`/`ClientToScreen`; null aplica e emite
  `move`. Falha de posicionamento nativo retorna `WindowMoveFailed`.
  Cobertura live X11 move uma janela e valida evento/posicao final
  (EWMH e fallback sem WM).
- Limites de tamanho da janela: `Window.setSizeLimits`/`sizeLimits`,
  `Platform.setWindowSizeLimits`/`windowSizeLimits` e
  `WindowSizeLimits` (mínimos e máximos da área de cliente; `max_* == 0`
  significa sem máximo explícito). X11 publica `WM_NORMAL_HINTS`
  (`PMinSize`/`PMaxSize`) preservando outros hints e confirma com
  `XGetWMNormalHints`; Win32 aplica em `WM_GETMINMAXINFO`; null mantém
  estado lógico. Min/max inválidos retornam `InvalidConfig`. Cobertura
  unitária e live X11 valida o round-trip nativo; Win32 apenas
  compilação cruzada.
- Modos de vídeo: `Platform.displayModes`/`setDisplayMode`, com
  `DisplayMode` (`id`, `width`, `height`, `refresh_mhz`, `current`,
  `preferred`) e `DisplayModeId` opaco. No X11 usa RandR
  (`XRRGetOutputInfo` para a lista, `XRRSetCrtcConfig` para a troca,
  com readback do CRTC e reajuste do tamanho da tela), preservando
  posição, rotação e outputs do CRTC. O layout de `XRROutputInfo` é
  detectado em runtime (difiere entre versões do Xrandr). Win32 e null
  devolvem lista vazia e `DisplayModeUnsupported`. Cobertura unitária
  (null) e live X11: enumeração no suite padrão e troca de modo em
  `zig build test-x11-modes` (passo destrutivo, restaura o modo).
- Clipboard nativo do Wayland: `wl_data_device`/`wl_data_source`/
  `wl_data_offer` com `text/plain;charset=utf-8` e `text/plain` —
  publicação assíncrona (o compositor pede os dados via `send`) e leitura
  síncrona com timeout. Limitação de validação: o KWin deste ambiente
  não entrega a seleção atual a clientes Wayland (confirmado com um
  cliente C de referência gerado pelo `wayland-scanner`), então o
  caminho de leitura fica sem exercício live; a publicação é verificada.
- Backend Wayland: `display_change` passa a ser emitido quando um
  output muda (modo, escala ou posição); as propriedades iniciais do
  compositor não geram evento espúrio.
- Backend Wayland **nativo** (não XWayland): conexão com o compositor,
  registry (`wl_display.get_registry` + `wl_registry.bind`), outputs
  (`wl_output` → `Platform.displays()` com tamanho lógico) e seat
  (`wl_seat.capabilities` → nova API `Platform.seatCapabilities()`),
  com despacho assíncrono sem bloquear. A libwayland-client é carregada
  em runtime (sem dependência de link) e as tabelas de interface do
  protocolo são escritas à mão em Zig, conferidas contra o código
  gerado por `wayland-scanner`. Validado contra o KWin 6.7.5 em Wayland
  nativo (`zig build test-wayland`). Janelas, input e clipboard do
  protocolo Wayland ainda não são implementados (`NotImplemented`).
- Input bruto de teclado: evento `raw_key` (`{ window, scancode, pressed,
  modifiers }`) com a tecla no nível de hardware — keycode do X11
  (evdev + 8 no Linux) ou scan code do Win32 (bits 16-23 do `lparam`).
  Permite distinguir teclas físicas que o `Key` agrupa e usar a tecla
  independentemente do layout; chega junto do `key_down`/`key_up`.
- Entrada de texto Unicode: evento `text_input` (`{ window, codepoint }`),
  um por codepoint, separado de `Key` (que continua sendo o input bruto
  da tecla). No X11 o codepoint vem do keysym (nível 0, ou nível 1 com
  Shift); no Win32 vem de `WM_CHAR` (UTF-16, com pares substitutos
  combinados), caminho pelo qual o IME confirma o texto composto.
  Compose/dead keys no X11 dependem de um input method (XIM) e ficam
  pendentes: a libX11 local não cria input context.
- Área de transferência: `Platform.setClipboardText`/`clipboardText`
  (UTF-8; o chamador libera a slice lida). No X11, a plataforma mantém
  uma janela oculta como dona da seleção `CLIPBOARD` e responde a
  `SelectionRequest` com `TARGETS`, `UTF8_STRING`,
  `text/plain;charset=utf-8`, `text/plain` (UTF-8) e `STRING`
  (Latin-1); a leitura é síncrona (até 500 ms, bombearando a conexão),
  tenta os alvos em ordem e converte a resposta Latin-1 para UTF-8, e
  a propriedade é lida em blocos de 64 KB. No Win32, `CF_UNICODETEXT` via `OpenClipboard`/
  `SetClipboardData`/`GetClipboardData`. No null, estado em memória.
  Limite de 1 MiB por texto.
- Correção no backend X11: a detecção de suporte EWMH
  (`_NET_SUPPORTED`) invertia o status de `XGetWindowProperty` (0 é
  sucesso nesta libX11) e por isso nunca detectava o WM. Agora
  posicionamento, fullscreen e maximização usam EWMH quando o WM
  anuncia suporte, com os caminhos de fallback cobrindo o caso sem WM.
- Modos de vídeo no Win32: `EnumDisplaySettingsW` para a lista e
  `ChangeDisplaySettingsExW` para a troca (dinâmica, sem gravar no
  registro). O `DisplayModeId` empacota largura, altura e índice do
  modo, recusando snapshots obsoletos (`InvalidDisplayMode`). Layouts de
  `DEVMODEW`/`MONITORINFOEXW` conferidos contra os headers reais do
  Windows; validação apenas por compilação cruzada (sem runtime
  Windows disponível).
- Maximização de janela: `Window.setMaximized`/`isMaximized`,
  `Platform.setWindowMaximized`/`isWindowMaximized` e
  `MaximizedEvent` (`{ window, maximized }`). X11 usa EWMH
  (`_NET_WM_STATE_MAXIMIZED_HORZ`/`_VERT`) com confirmação por
  `PropertyNotify` e fallback de geometria; Win32 usa
  `ShowWindow(SW_MAXIMIZE/SW_RESTORE)`/`IsZoomed` e também reage a
  `WM_SIZE`; null mantém estado lógico. Fullscreen e maximizado são
  mutuamente exclusivos (`WindowStateFailed`). Cobertura unitária e live
  X11 (EWMH e fallback sem WM); Win32 apenas compilação cruzada.
- Fullscreen de janela: `Window.setFullscreen`/`isFullscreen`,
  `Platform.setWindowFullscreen`/`isWindowFullscreen` e evento
  `FullscreenEvent` (`{ window, fullscreen }`). X11 usa
  `_NET_WM_STATE_FULLSCREEN` via EWMH e confirma por `PropertyNotify`;
  sem WM/EWMH aplica geometria na tela X padrão e restaura ao sair.
  Win32 remove a moldura (`WS_POPUP`) e cobre o monitor mais próximo,
  restaurando estilo/retângulo; null mantém estado lógico e emite o
  evento. Falha nativa retorna `WindowStateFailed`. Exemplo
  `fullscreen.zig`; cobertura live X11 valida EWMH (KWin) e fallback
  (Xwayland); Win32 apenas compilação cruzada.
- Evento `display_change` (`DisplayChangeEvent`, sem payload) para
  reconfiguracao de monitores/display. X11 seleciona
  `RRScreenChangeNotify`/`RRNotify` via `libXrandr` opcional e atualiza o
  cache da Xlib; Win32 trata `WM_DISPLAYCHANGE`; null aceita
  `injectEvent`. O evento e coalescido quando adjacente e nao tem
  janela associada; uma mudanca nativa pode gerar mais de um aviso.
  Exemplo `display_change.zig`; mudanca de resolucao/evento validados em
  Xwayland, hotplug fisico nao testado.

## [0.1.0-alpha.2] — 2026-10-19

Segunda etapa: endurecimento de lifecycle, CI e cobertura de regressão
(input, mouse, modificadores e auto-repeat validados em runtime no X11).

### Corrigido

- `Platform.deinit` idempotente + guards pós-deinit (`PlatformClosed`,
  no-ops e falhas seguras em vez de use-after-free/double-free).
- Perda de foco libera teclas/botões pressionados com eventos
  sintéticos (`input.releaseAll` no `FocusOut`/`WM_KILLFOCUS`):
  nada fica preso após Alt+Tab.
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
- X11 marca `repeat=true` em auto-repeat: `init` habilita *detectable
  autorepeat* (XKB, `XkbSetDetectableAutoRepeat`, parte da Xlib), de
  modo que o servidor envia apenas `KeyPress` repetidos. Antes, toda
  repetição chegava como `key_down` sem distinção (`repeat` sempre
  `false`). Servidor sem suporte mantém o fallback seguro
  (`repeat=false`), e `Key.unknown` nunca é marcado como repetição.
- X11: teclado numérico agora mapeia para as mesmas teclas lógicas do
  Win32 — `n0-n9` e `enter` com NumLock ligado; navegação (`home`,
  setas, `page_up`/`page_down`, `insert`, `delete`, `end`) com NumLock
  desligado. Antes caía em `.unknown`. Operadores (`+`, `*`, `/`)
  seguem `.unknown` em ambos os backends (sem variante em `Key`).
- Win32 deriva `modifiers` do estado autoritativo (`GetKeyState`) em vez
  de rastreamento incremental. Corrige o modificador preso após perda
  de foco (o estado do backend não era limpo no `WM_KILLFOCUS`, e o
  `key_up` do modificador pode nunca chegar) e o caso de Shift/Ctrl/Alt
  esquerdo e direito pressionados ao mesmo tempo (soltar um zerava o
  outro). O mapeamento de `Key` segue genérico por VK (sem lado).

### Adicionado

- `Event.window()`: janela associada ao evento, quando houver
  (usado pela poda de eventos de janelas destruídas).
- `Platform.droppedEvents()`: total de eventos descartados por
  overflow desde o init, exposto como diagnóstico público (antes
  acessível apenas pelo campo interno `events.dropped`).
- Cobertura de regressão: reuso de slot/geração no nível Platform,
  destroy durante o consumo, poda mista, deinit com janelas vivas,
  cópia + double-deinit, falha de alocação em `createWindow`, stress
  de 32 janelas, `InvalidWindow` em ops sobre id morto, ordenação de
  overflow, transições de botões/modificadores/scroll, limpeza de
  `pointer_window` no destroy e consistência do estado de input sob
  descarte por overflow.
- Testes live X11 (`zig build test-x11`, display real; pulam sem
  display): ciclo create/poll/resize, erro de protocolo não encerra o
  processo, destruição externa (servidor) — `close` uma única vez,
  entrada nativa removida (ops retornam `InvalidWindow`) e slot
  preservado até o consumidor destruir —, independência de múltiplas
  janelas simultâneas (ids distintos, resize isolado, destroy não
  afecta a outra, poda de eventos da janela destruída), visibilidade
  via Map/Unmap (`setVisible` → `UnmapNotify`/`MapNotify` →
  `isWindowVisible`) e foco via FocusIn/FocusOut (`focus()` →
  `XSetInputFocus` → `isWindowFocused`; degrada graciosamente sem WM).
- Testes live X11 de mouse e modificadores (eventos sintéticos via
  `XSendEvent`): `MotionNotify` atualiza evento + `InputState`
  (coordenadas), botões esquerdo/médio/direito com `pressed` e
  modificadores, roda vertical/horizontal (botões 4–7) com sinal
  correto, e `Shift`/`Ctrl`/`Alt`/`Super` derivados do `state` do
  servidor em `key_down`/`key_up`.
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
