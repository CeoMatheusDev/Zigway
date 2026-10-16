# API — Zigway v0.1.0-alpha.1

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
platform.isWindowVisible(id) bool
platform.isWindowFocused(id) bool
platform.windowShouldClose(id) bool      // inválido -> true
platform.requestWindowClose(id) void
platform.setWindowTitle(id, title) !void
platform.setWindowSize(id, w, h) !void   // slot reflete o CONFIRMADO
platform.setWindowVisible(id, v) !void
platform.focusWindow(id) !void           // melhor esforço
```

## Window (handle `{id, *Platform}`)

```zig
defer window.deinit();            // infalível; inválido é ignorado
window.windowId() WindowId
window.isValid() bool
window.shouldClose() bool
window.requestClose() void
window.setTitle/setSize/setVisible/focus  // !void
window.size() WindowSize
```

## Eventos

```zig
pub const Event = union(enum) {
    close: CloseEvent,              // { window: WindowId }
    resize: ResizeEvent,            // { window, width, height }
    focus: FocusEvent,               // { window, focused }
    key_down / key_up: KeyEvent,     // { window: ?WindowId, key, modifiers, repeat }
    pointer_move: PointerMoveEvent,  // { window: ?WindowId, x, y }
    pointer_button: PointerButtonEvent,
    scroll: ScrollEvent,             // { window: ?WindowId, dx, dy }
};
```

Fila: capacidade fixa, sem alocação após init; coalescing de
`pointer_move` adjacente; overflow preserva `close` (`dropped` conta
descartes). Eventos carregam só ids/escalares — destruir a janela
poda seus eventos pendentes (seguro destruir durante o consumo da
fila: `nextEvent` não retém índices). `Event.window()` retorna a
janela associada, quando houver.

Teclas sem mapeamento geram eventos com `.key == .unknown` (não são
filtradas); o estado de input as registra normalmente.

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

## Tipos e erros

`BackendKind` (com `.auto`), `ActiveBackend`, `WindowId` (`eql`,
`eqlOpt`, `invalid`), `DisplayId` (reservado, Fase 2), `Modifiers`
(1 byte), `WindowSize`, `WindowPosition`, `version.string`
(`"0.1.0-alpha.1"`).

Erros (`core/errors.zig` + `OutOfMemory`): `UnsupportedBackend`,
`NotImplemented`, `NoDisplay`, `ConnectionFailed`, `InvalidConfig`,
`WindowCreationFailed`, `InvalidWindow`.
