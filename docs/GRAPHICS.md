# Graphics — integração com APIs gráficas

Status: **OpenGL via EGL no X11 implementado, não validado em runtime pelo
autor do patch**. Vulkan, Direct3D e os demais backends seguem **não
implementados**.

## Responsabilidades

**Zigway (integração nativa da janela):**

- Expor o handle nativo da janela (`Window.nativeHandle()`).
- OpenGL: criar/destruir contexto e superfície, tornar o contexto ativo,
  trocar buffers, intervalo de swap e carregar funções (`zigway.gl`).
- Vulkan: extensões de instância por backend e `VkSurfaceKHR` (planejado).
- Direct3D 11/12 (Win32): handles para swapchains DXGI (planejado).

**Renderer/RHI da engine (fora do Zigway):**

- Dispositivos, filas, command lists, pipelines, swapchains, frames.

O Zigway **nunca** implementará um renderer. Criar janelas nunca exige
Vulkan/OpenGL/Direct3D; as bibliotecas gráficas só são carregadas (em
runtime, via `std.DynLib`) quando a integração é pedida.

## Handle nativo

```zig
const handle = try window.nativeHandle(); // zigway.NativeHandle
switch (handle) {
    .x11 => |h| { _ = h.display; _ = h.window; _ = h.visual_id; },
}
```

Os valores são emprestados: valem enquanto a janela e a `Platform` existirem.
Backends sem suporte retornam `error.NotImplemented`.

## OpenGL (`zigway.gl`)

```zig
var ctx = try zigway.gl.Context.init(window, .{ .major = 3, .minor = 3 });
defer ctx.deinit();                 // ANTES de window.deinit / platform.deinit
try ctx.makeCurrent();
const glClear = ctx.getProc(*const fn (u32) callconv(.c) void, "glClear").?;
// ... desenhar ...
try ctx.swapBuffers();
```

- `libEGL.so.1` (ou `libEGL.so`) é procurada em runtime; sem ela,
  `error.GraphicsUnavailable`. Não há dependência de link.
- A configuração EGL é escolhida para casar com o visual da janela (exigência
  do X11) com RGB >= 8 bits e suporte a janela + OpenGL.
- Perfil core por padrão (`Options.core_profile`); `vsync` por padrão.
- Exemplo: `zig build examples` gera `gl_clear`.

Limitações desta versão:

- Um `Context` por `Platform` (`deinit` termina o `EGLDisplay`).
- Somente X11 (no Wayland, rode o backend X11 via XWayland:
  `Platform.init(allocator, .{ .backend = .x11 })`).
- Sem teste automatizado de runtime: o teste headless cobre apenas o caminho
  de erro (backend null). A validação em display real é manual.

## Estado por backend

| Backend | Handle nativo | OpenGL (EGL) | Vulkan | Direct3D |
|---|---|---|---|---|
| X11 | sim | sim (não validado em runtime) | planejado | n/a |
| Wayland | não | não | planejado | n/a |
| Win32 | não | não (WGL planejado) | planejado | planejado |
| Null | não | não | não | não |
