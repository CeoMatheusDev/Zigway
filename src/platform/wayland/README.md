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
  `wl_output` e `wl_seat`.
- **Outputs (monitores)**: `wl_output` (geometry, mode, scale, name) →
  `Platform.displays()` com posição e tamanho lógico (modo ÷ escala).
- **Seat**: `wl_seat.capabilities` → `Platform.seatCapabilities()`
  (ponteiro/teclado/toque).
- **Despacho assíncrono**: leitura do socket sem bloquear
  (`wl_display_prepare_read`/`read_events`/`dispatch_pending`).
- **Tabelas de interface**: o equivalente Zig do código gerado por
  `wayland-scanner` (`src/platform/wayland/protocol.zig`), conferidas
  contra a referência gerada.

## Ainda NÃO implementado

- **Janelas/superficies**: `wl_surface` + `xdg_wm_base`/`xdg_surface`/
  `xdg_toplevel` (as tabelas de interface já estão escritas).
- **Input**: teclado (exige o keymap XKB) e ponteiro (exige superfície).
- **Clipboard**: `wl_data_device_manager`/`wl_data_source`/`wl_data_offer`.
- **Modos de vídeo**: o Wayland delega a troca ao compositor.

Até lá, `createWindow` e as operações de janela retornam
`error.NotImplemented`; `displays()` e `seatCapabilities()` funcionam.

## Teste

```sh
zig build test-wayland
```

Pula graciosamente (sem falhar) quando não há compositor Wayland
(`WAYLAND_DISPLAY`/socket ausente) ou quando a libwayland-client não
está instalada. O mesmo vale para `zig build test` (não exige display).
