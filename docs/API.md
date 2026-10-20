# API — Zigway v0.1.0-alpha.2

Referência da API pública real (`@import("zigway")`). Nada aqui é
aspiracional: se não está no código, não está neste documento.

## Platform

```zig
pub const PlatformOptions = struct {
    backend: BackendKind = .auto,   // auto | x11 | win32 | null_backend | wayland
    event_queue_capacity: usize = 256,
};

var platform = try zigway.Platform.init(allocator, .{});
defer platform.deinit();

platform.backendKind() -> ActiveBackend   // win32 | x11 | null_backend
platform.runtimeCaps() -> RuntimeCaps
platform.pollEvents() void               // drena o SO para a fila
platform.nextEvent() ?Event              // consome a fila
platform.injectEvent(Event) void         // evento sintético (testes)
platform.inputState() *const InputState
platform.droppedEvents() u64             // descartes por overflow (diagnóstico)
platform.displays(allocator) ![]DisplayInfo // snapshot; liberar com o allocator
```

Janelas via Platform:

```zig
var w = try platform.createWindow(.{
    .width = 1280, .height = 720,
    .title = "Zigway",              // []const u8, máx. 1024 bytes
    .resizable = true, .visible = true,
});
try platform.destroyWindow(id);
platform.isWindowAlive(id) bool
platform.windowSize(id) WindowSize       // inválido -> {0,0}
platform.windowPosition(id) WindowPosition // origem da área de cliente; inválido -> {0,0}
platform.isWindowVisible(id) bool
platform.isWindowFocused(id) bool
platform.windowShouldClose(id) bool      // inválido -> true
platform.requestWindowClose(id) void
platform.setWindowTitle(id, title) !void
platform.setWindowSize(id, w, h) !void   // slot reflete o CONFIRMADO:
                                 // nativo confirma via evento; null aplica na hora
platform.setWindowPosition(id, x, y) !void // origem da área de cliente;
                                 // X11 confirma via evento `move`
platform.setWindowVisible(id, v) !void
platform.focusWindow(id) !void           // melhor esforço
platform.setWindowCursor(id, cursor) !void
platform.captureWindowPointer(id) !void
platform.releaseWindowPointer(id) void // idempotente/best-effort
```

## Window (handle `{id, *Platform}`)

```zig
defer window.deinit();            // infalível; inválido é ignorado
window.windowId() WindowId
window.isValid() bool
window.shouldClose() bool
window.requestClose() void
window.setTitle/setSize/setVisible/focus  // !void
window.setCursor(Cursor) !void   // cursor do sistema, por janela
window.capturePointer() !void    // captura exclusiva por Platform
window.releasePointer() void     // idempotente; seguro em defer
window.size() WindowSize
window.position() WindowPosition
window.setPosition(x, y) !void
```

## Displays

```zig
const displays = try platform.displays(allocator);
defer allocator.free(displays);

for (displays) |info| {
    _ = info.id;      // DisplayId (eql/isValid)
    _ = info.x;       // i32, relativo ao espaço de tela do backend
    _ = info.y;       // i32
    _ = info.width;   // u32, pixels
    _ = info.height;  // u32, pixels
    _ = info.primary; // bool, conforme reportado pelo sistema
}
```

`DisplayInfo` é um snapshot: cada chamada consulta o estado atual, então
hotplug/reconfiguração pode mudar a quantidade, a ordem e os `id`s.
Mudanças são sinalizadas pelo evento `display_change` (sem payload):
reconsulte `displays()` para obter o novo snapshot. X11 usa RandR 1.5+
quando `libXrandr.so.2` está disponível em runtime; sem ela (ou sem
RandR 1.5) reporta X screens, cada uma com origem `(0,0)` (espaços de
coordenadas independentes). Se `libXrandr` e a extensão RandR expõem
`XRRQueryExtension`/`XRRSelectInput`, notificações de tela/CRTC/output
são emitidas mesmo quando `displays()` cai para X screens; sem a
biblioteca ou a extensão não há evento nativo. Win32 usa
`EnumDisplayMonitors` e trata `WM_DISPLAYCHANGE` nas janelas. O backend
null não inventa monitores: retorna lista vazia; `display_change` pode
ser injetado. Em plataforma fechada a lista também é vazia. Não há troca
de modo de vídeo.

## Posição de janela

`WindowPosition` é a origem da **área de cliente** em coordenadas de tela
do backend (não inclui decoração/título). `windowPosition`/`position`
consultam o recurso nativo quando possível; após `deinit` ou para um id
inválido retornam `{0,0}`. `setPosition` é uma requisição: o WM pode
ajustar, restringir ou ignorar a posição, e a confirmação chega pelo
evento `move` (no X11, no próximo `pollEvents`). X11 usa
`_NET_MOVERESIZE_WINDOW` com `StaticGravity` quando o WM anuncia suporte
em `_NET_SUPPORTED`; sem WM/EWMH cai para `XMoveWindow`. Win32 posiciona
a janela externa preservando o delta até a área de cliente. Null aplica
na hora e emite `move`.

## Eventos

```zig
pub const Event = union(enum) {
    close: CloseEvent,              // { window: WindowId }
    resize: ResizeEvent,            // { window, width, height }
    move: MoveEvent,                // { window, x, y } origem do cliente
    display_change: DisplayChangeEvent, // sem payload; reconsultar displays()
    focus: FocusEvent,              // { window, focused }
    key_down / key_up: KeyEvent,     // { window: ?WindowId, key, modifiers, repeat }
    pointer_move: PointerMoveEvent,  // { window: ?WindowId, x, y }
    pointer_button: PointerButtonEvent,
    scroll: ScrollEvent,             // { window: ?WindowId, dx, dy }
};
```

Fila: capacidade fixa, sem alocação após init; coalescing de
`pointer_move` adjacente e de `display_change` adjacente; overflow
preserva `close` (`dropped` conta descartes). Uma reconfiguração nativa
pode gerar mais de um `display_change` (RandR emite screen/crtc/output
em momentos distintos); reconsultar `displays()` é idempotente. Eventos
carregam só ids/escalares — destruir a janela poda seus eventos
pendentes (seguro destruir durante o consumo da fila: `nextEvent` não
retém índices). `Event.window()` retorna a janela associada, quando
houver; `display_change` não tem janela.

Teclas sem mapeamento geram eventos com `.key == .unknown` (não são
filtradas); o estado de input as registra normalmente.

Perda de foco libera o que estava pressionado: o backend emite
`key_up` para cada tecla e `pointer_button` solto para cada botão
(associados à janela que perdeu o foco, modificadores zerados), pois
o SO não entregará os ups correspondentes. Sem isso, entradas
ficariam presas após Alt+Tab.

## Input

```zig
state.isKeyDown(Key) bool
state.isButtonDown(MouseButton) bool
state.modifiers: Modifiers           // shift/control/alt/super
state.pointer_x / pointer_y: i32
state.pointer_window: ?WindowId
```

`Key`: `unknown`, `a-z`, `n0-n9`, `f1-f12`, escape/tab/enter/backspace/
delete/insert/home/end/page_up/page_down, setas, shifts/controls/alts/
supers, caps_lock, num_lock, pontuação comum. `MouseButton`:
left/right/middle/back/forward (roda chega como `scroll`).

`Cursor`: `default`, `text`, `crosshair`, `hand`, `resize_horizontal`,
`resize_vertical`, `resize_all`, `not_allowed`, `wait`. O mapeamento é
por backend; `.default` é a seta padrão do SO e `.not_allowed` usa
`XC_X_cursor` no X11 (o cursorfont não tem forma "proibido" dedicada).

Captura de ponteiro: exclusiva por `Platform` (no Win32 a captura é
por thread, então duas instâncias na mesma thread compartilham o estado
do SO); capturar outra janela da mesma instância transfere a captura (a
anterior é liberada antes da nova tentativa; se a nova falhar, nenhuma
fica capturada). `releasePointer` é idempotente e não falha (seguro em
`defer`), inclusive após `deinit` ou para id inválido. Durante a captura
os eventos de ponteiro continuam chegando pela janela capturada mesmo
fora de seus limites; o ponteiro não é confinado.

`pointer_window` é limpo quando a janela correspondente é destruída
(`InputState.forgetWindow`), evitando referência a id morto. Teclas e
botões são estado global e não são associados a janela.

## Tipos e erros

`BackendKind` (com `.auto`), `ActiveBackend`, `WindowId` (`eql`,
`eqlOpt`, `invalid`), `DisplayId` (`eql`, `isValid`, `invalid`),
`DisplayInfo`, `Modifiers` (1 byte), `WindowSize`, `WindowPosition`,
`MoveEvent`, `DisplayChangeEvent`, `version.string` (`"0.1.0-alpha.2"`).

Erros (`core/errors.zig` + `OutOfMemory`): `UnsupportedBackend`,
`NotImplemented`, `NoDisplay`, `ConnectionFailed`, `InvalidConfig`,
`WindowCreationFailed`, `WindowMoveFailed`, `CursorCreationFailed`,
`PointerCaptureFailed`, `InvalidWindow`, `PlatformClosed`.

## Lifecycle

- `Platform` tem ownership único e intransferível (não copiar o valor).
- `deinit` é idempotente; após ele, mutações retornam
  `error.PlatformClosed`, `pollEvents`/`injectEvent` são no-ops,
  `nextEvent` retorna `null`, `displays` retorna lista vazia e
  consultas usam falha segura.
- `Window.deinit` após `deinit` da plataforma é ignorado com segurança.
- Ordem correta: `defer window.deinit()` registrado **depois** do
  `defer platform.deinit()` (LIFO garante janela antes da plataforma).
- Múltiplas instâncias `Platform` coexistem com recursos independentes
  (filas, inputs, ids e — no Win32 — classes de janela não se misturam).
