# Backend Wayland — NÃO IMPLEMENTADO

Status: planejado para **v0.5.0** (ver roadmap no CHANGELOG/docs).

Este diretório existe apenas para reservar o ponto de extensão. Não há
código aqui de propósito: a especificação proíbe implementação fictícia
e proíbe anunciar Wayland como disponível antes de validação.

O modelo previsto (quando implementado):

- Connection (wl_display via socket wayland).
- Registry + protocol binding (wl_compositor, xdg_wm_base, wl_seat...).
- Surface management (wl_surface + xdg_surface/toplevel).
- Seat: keyboard + pointer.
- Output (monitores).
- Event dispatch respeitando o modelo assíncrono e as regras de
  ownership dos objetos Wayland.

Até lá:

- `caps.compile_caps.has_wayland == false`.
- `Platform.init(.{ .backend = .wayland })` retorna `error.NotImplemented`.
- `zig build -Dplatform=wayland` falha com mensagem clara.
- Execução via XWayland conta como backend **X11**, não Wayland.
