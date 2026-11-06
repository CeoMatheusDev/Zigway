# Graphics — integração com APIs gráficas

Status: **superfície Vulkan (X11/Win32/Wayland) e OpenGL via EGL (X11)
implementados e compilando em todos os alvos; nenhum dos dois foi validado
em runtime ainda** (exige display real + `libvulkan`/`libEGL`). Direct3D
segue **não implementado**.

## Responsabilidades

**Zigway (integração nativa da janela):**

- Expor o handle nativo da janela (`Window.nativeHandle()`).
- Vulkan: extensões de instância por backend, criação/destruição de
  `VkSurfaceKHR` e carregamento da libvulkan (`zigway.vulkan`).
- OpenGL: criar/destruir contexto e superfície, tornar o contexto ativo,
  trocar buffers, intervalo de swap e carregar funções (`zigway.gl`).
- Direct3D 11/12 (Win32): handles para swapchains DXGI (planejado).

**Renderer/RHI da engine (fora do Zigway):**

- Dispositivos, filas, command lists, pipelines, swapchains, frames.

O Zigway **nunca** implementará um renderer. Criar janelas nunca exige
Vulkan/OpenGL/Direct3D; as bibliotecas gráficas só são carregadas em
runtime quando a integração é pedida.

## Handle nativo

```zig
const handle = try window.nativeHandle(); // zigway.NativeHandle
switch (handle) {
    .x11 => |h| { _ = h.display; _ = h.window; _ = h.visual_id; },
}
```

Os valores são emprestados: valem enquanto a janela e a `Platform` existirem.
Backends sem suporte retornam `error.NotImplemented`.

## Vulkan (`zigway.vulkan`)

O Zigway não cria a `VkInstance` (isso é da engine): fornece as extensões
que o backend exige e cria a superfície com a instância do chamador.

```zig
var vk_lib = zigway.vulkan.Lib.load() orelse return error.VulkanUnavailable;
defer vk_lib.deinit();

// Criar a VkInstance habilitando platform.vulkanExtensions()
const surface = try platform.createVulkanSurface(window, vk_instance, &vk_lib);
defer platform.destroyVulkanSurface(vk_instance, surface, &vk_lib);
```

- `libvulkan` carregada em runtime (`std.DynLib`; no Windows via
  `LoadLibraryA`/`GetProcAddress`, já que o `std.DynLib` 0.17.0 não tem
  backend para Windows). Sem a biblioteca, `Lib.load()` retorna `null`.
- Funções de extensão resolvidas por `vkGetInstanceProcAddr`; nenhum
  símbolo Vulkan é linkado no build.
- `platform.vulkanExtensions()` retorna slice estática (sem alocação):
  `VK_KHR_xlib_surface` (X11), `VK_KHR_win32_surface` (Win32),
  `VK_KHR_wayland_surface` (Wayland); vazia no backend null.
- `platform.graphicsCapabilities()` informa o que o backend oferece; é
  consulta de capacidade, não de validação em runtime.
- Ownership: destruir a superfície antes de `window.deinit`/`platform.deinit`.

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

## O que ainda não existe

- Contexto OpenGL no Win32 (WGL) e no Wayland (EGL sobre `wl_display`).
- Handles Direct3D/DXGI no Win32 (`graphicsCapabilities().direct3d_handle`
  permanece `false`).
- Validação em runtime das superfícies Vulkan (`vkCreate*SurfaceKHR`) e do
  contexto EGL: ambos exigem GPU/driver. Enquanto não houver essa
  validação, nenhum dos dois deve ser anunciado como pronto para produção.

## Estado por backend

| Backend | Handle nativo | Vulkan (superfície) | OpenGL (EGL) | Direct3D |
|---|---|---|---|---|
| X11 | sim | implementado, não validado em runtime | implementado, não validado em runtime | n/a |
| Wayland | não | implementado, não validado em runtime | não | n/a |
| Win32 | não | implementado, não validado em runtime | não (WGL planejado) | planejado |
| Null | não | não | não | não |
