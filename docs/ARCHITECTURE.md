# Arquitetura — Zigway (Fase 1)

## Camadas

```text
APPLICATION (engine / GUI / app)
        │
ZIGWAY PUBLIC API (src/root.zig, window.zig, events.zig, input.zig)
        │
PLATFORM ABSTRACTION (platform.zig, backend.zig, registry.zig)
        │
NATIVE BACKENDS (null_backend, x11/, win32/; wayland/ reservado)
```

Regras de dependência:

- `core/*` não importa nada além de `std` (+ `builtin` em caps).
- `events`/`input` importam apenas `core`.
- `registry` importa `core` + `window` (tipos de config).
- Backends importam `registry`, `events`, `input`, `window`, `core`.
  **Nunca** importam `platform` (sem ciclo backend↔platform).
- `platform` importa backends + `window` + `registry` + `events/input`.
- `window` importa `platform` **apenas para o tipo `*Platform`**.
  Este é o único par com import mútuo, deliberado e documentado:
  `Window` é um handle `{id, *Platform}` e seus métodos delegam ao
  dono. Nenhum dado flui de `window` para `platform` em tempo de
  compilação além do tipo.

## Ownership e lifetime

- `Platform.init(allocator, options)` adquire: fila (capacidade fixa),
  backend nativo (display / classe de janela). Falha parcial desaloca
  o já adquirido (`errdefer`).
- `createWindow` reserva slot → cria nativa → em falha libera o slot.
  O slot guarda `should_close`, tamanho, foco, visibilidade + handle
  nativo opaco (`native_id` no X11, `native_ptr` no Win32).
- `Window.deinit()` destrói a nativa, libera o slot (geração+1) e poda
  eventos pendentes da janela. É infalível (para `defer`); janela
  inválida é ignorada.
- `Platform.deinit()` destrói nativas restantes, fecha o backend, libera
  fila e registro. Ordem: janelas → backend → registro → fila.

## Handles geracionais

`WindowId = {index, generation}`. Reutilizar um slot incrementa a
geração; ids antigos falham em `get()` em vez de atingir outra janela.
`windowShouldClose` com id inválido retorna `true` (falha segura:
loops de exemplo encerram em vez de girar).

## Eventos

`pollEvents()` drena tudo do SO para a fila e atualiza o `InputState`
no mesmo passo (`events.dispatch` — ponto único). `nextEvent()` consome.
Sem alocação após o init; capacidade fixa; overflow preserva `close`
(ver `events.zig`). Eventos de janela destruída são podados no destroy.

## Threading

Afinidade com a thread criadora: `init`, `pollEvents` e operações de
janela devem rodar na mesma thread. Não há sincronização interna
(decisão consciente: evita custo e falsa sensação de segurança).

## Seleção de backend

`-Dplatform` (build) define o padrão para `Options.backend == .auto`;
`resolve()` valida em runtime (alvo errado → `UnsupportedBackend`,
Wayland → `NotImplemented`). O despacho usa `switch ... inline else`
sobre uma união por-alvo, de modo que código Win32 nunca referencia
símbolos user32 em binários Linux (e vice-versa).
