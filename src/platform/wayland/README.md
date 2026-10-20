# Backend Wayland — em andamento (v0.5)

Backend **nativo** do protocolo Wayland (wire protocol direto com o
compositor). Não é XWayland: uma sessão XWayland continua sendo tratada
pelo backend X11.

A libwayland-client é carregada em **runtime** (`dlopen` de
`libwayland-client.so.0`), como a libXrandr no backend X11: o build não
ganha dependência de link e, sem a biblioteca, o backend simplesmente
não está disponível (`error.UnsupportedBackend`).

## Implementado (validado contra o KWin 6.7.5)

- **Conexão**: `wl_display_connect` (socket `WAYLAND_DISPLAY`).
- **Registry**: `wl_display.get_registry` + `wl_registry.bind` de
  `wl_output`, `wl_seat`, `wl_compositor`, `wl_shm` e `xdg_wm_base`.
- **Outputs (monitores)**: `wl_output` (geometry, mode, scale, name) →
  `Platform.displays()` com posição e tamanho lógico (modo ÷ escala).
- **Seat**: `wl_seat.capabilities` → `Platform.seatCapabilities()`
  (ponteiro/teclado/toque).
- **Janelas (xdg-shell)**: `wl_surface` + `xdg_surface` +
  `xdg_toplevel`, com título, app id, limites de tamanho, maximização
  e fullscreen. O `configure` do compositor é confirmado com
  `ack_configure` e o cliente anexa um buffer `wl_shm` (pool + buffer
  por janela, `memfd` + `mmap`) para mapear a superfície. Eventos:
  `resize` (tamanho aceito pelo compositor), `maximized`, `fullscreen`
  e `close`.
- **Teclado**: o `wl_keyboard` é criado quando o compositor anuncia a
  capacidade no seat. O `keymap` (formato texto XKB, entregue por um
  descritor) é interpretado pela **libxkbcommon**, carregada em runtime
  (`dlopen`), como a libwayland: sem ela o teclado não entrega teclas e
  o resto do backend continua funcionando. O keycode vira keysym (com
  layout e modificadores) e depois na tecla lógica da API
  (`src/platform/keysym.zig`, compartilhado com o X11). `enter`/`leave`
  viram `focus` (a perda de foco libera as teclas pressionadas) e
  `key` vira `key_down`/`key_up` com os modificadores do evento
  `modifiers` do compositor. O `raw_key` traz o keycode XKB
  (evdev + 8, como o keycode do X11).
- **Ponteiro**: o `wl_pointer` é criado quando o compositor anuncia a
  capacidade no seat. `enter`/`leave`/`motion` viram `pointer_move`
  (com a janela da superfície), `button` vira `pointer_button` e `axis`
  vira `scroll` (publicado no `frame`).
- **Ping**: `xdg_wm_base.ping` é respondido com `pong` (sem isso o
  compositor considera o cliente travado).
- **Despacho assíncrono**: leitura do socket sem bloquear
  (`wl_display_prepare_read`/`read_events`/`dispatch_pending`), com
  flush das requisições pendentes.
- **Tabelas de interface**: o equivalente Zig do código gerado por
  `wayland-scanner` (`src/platform/wayland/protocol.zig`), conferidas
  contra a referência gerada (incluindo as tabelas de argumentos, que
  definem a validação de tipos no demarshal).

## Ainda NÃO implementado

- **Clipboard**: `wl_data_device_manager`/`wl_data_source`/`wl_data_offer`.
- **Modos de vídeo**: o Wayland delega a troca ao compositor.
- **Equivalentes do X11/Win32 sem contraparte no protocolo base**:
  `setSize` (o compositor decide o tamanho), `setPosition` (a posição
  não é exposta ao cliente), `focus` (o foco é do compositor), cursor do
  sistema e captura exclusiva de ponteiro.

## Buffer provisório

Para mapear a superfície, o cliente anexa um buffer `wl_shm` com uma cor
sólida (o conteúdo real vem da fase de gráficos, v0.4). O descritor do
`memfd` é enviado ao compositor via SCM_RIGHTS e só é fechado depois
que a requisição foi enviada (flush).

## Ordem do `configure` (armadilhas do protocolo)

O xdg-shell é estrito e o compositor recusa a conexão (abortando o
cliente) em dois casos:

- **buffer antes do `ack_configure`** (`unconfigured_buffer`): nenhum
  buffer pode ser anexado antes de o `configure` ser confirmado;
- **buffer com tamanho diferente do `configure`** (`invalid_size`): o
  buffer precisa ter o tamanho aceito pelo compositor.

Por isso o backend separa as duas coisas: o `ack_configure` sai assim
que o serial chega (`xdg_surface.configure`) e o buffer só é anexado
quando o tamanho também é conhecido (`xdg_toplevel.configure`). O
compositor pode enviar os dois eventos em qualquer ordem — o backend
trata as duas.

## Teste

```sh
zig build test-wayland
```

Pula graciosamente (sem falhar) quando não há compositor Wayland
(`WAYLAND_DISPLAY`/socket ausente) ou quando a libwayland-client não
está instalada. O mesmo vale para `zig build test` (não exige display).
