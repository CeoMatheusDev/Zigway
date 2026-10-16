# Backends — cobertura e limitações (v0.1.0-alpha.1)

## X11 (`src/platform/x11/`)

ABI Xlib declarada manualmente (`api.zig`), layouts conferidos contra o
header do sistema. Link dinâmico com `libX11.so` (dependência de sistema
documentada — não é pacote Zig, não usa `@cImport`).

Cobertura: abrir/fechar display, criar/destruir, mapear/desmapear,
título, resize, foco, `WM_DELETE_WINDOW` (close, com checagem de
`WM_PROTOCOLS`), teclado via `XLookupKeysym`, mouse (movimento,
5 botões, roda vertical/horizontal), modificadores
(Shift/Ctrl/Alt/Super), multi-janelas.

Destruição externa (servidor/WM mata a janela): o backend marca
`should_close`, emite `close` uma vez e remove a entrada nativa —
operações seguintes retornam `InvalidWindow` em vez de atingir XID
morta (o handler padrão de erros X encerra o processo em `BadWindow`).
O slot segue ocupado até `destroyWindow` do consumidor.

Limitações conhecidas:

- Auto-repeat chega como `key_down` repetidos (`repeat=false`).
- Mapeamento keysym→`Key` cobre o conjunto documentado; o restante é
  `.unknown` (não falha).
- `focus()` usa `XSetInputFocus` (melhor esforço; o WM pode recusar).
- Posição absoluta da janela não é controlada (limite do protocolo).
- XWayland conta como backend X11 (sem código Wayland nativo).

Validado com display real: `zig build test-x11`.

## Win32 (`src/platform/win32/`)

ABI user32/kernel32/gdi32 declarada manualmente (`api.zig`, layouts
para 64-bit). Sem link com CRT além do necessário.

Cobertura: registro de classe (nome único por instância, permitindo
múltiplas `Platform` no mesmo processo), `CreateWindowExW` (área de cliente
ajustada via `AdjustWindowRectEx`), `WndProc` + pump com `PeekMessageW`,
teclado (VK→`Key`, flag `repeat` via bit 30, modificadores incrementais
+ flags `MK_*` no mouse), mouse (movimento, 5 botões, wheel
vertical/horizontal com `ScreenToClient`), `WM_SIZE` (inclui minimize
como invisível), foco, `WM_CLOSE`→evento sem destruir, multi-janelas.

Destruição externa: como no X11, a entrada nativa é removida e
operações seguintes retornam `InvalidWindow`; o slot segue ocupado
até `destroyWindow` do consumidor.

Limitações conhecidas:

- Sem validação em runtime ainda (validado por compilação cruzada
  `x86_64-windows`; sem máquina Windows disponível).
- Numpad 0–9 mapeados para `n0`–`n9` (sem distinção nesta fase).
- Estado inicial de modificadores é `false` até o primeiro evento.
- `focus()` usa `SetFocus` (melhor esforço; foreground pertence ao SO).

## Wayland

Não implementado. Ver `src/platform/wayland/README.md`.

## null

Headless: sem recursos nativos; eventos via `injectEvent`. Usado pelos
testes unitários e como fallback em SOs sem backend.
