# Graphics — integração planejada (v0.4.x)

Status: **não implementado**. Este documento fixa o contrato para não
haver deriva quando a fase chegar.

## Responsabilidades

**Zigway (integração nativa da janela):**

- Vulkan: extensões de instância necessárias por backend, criação de
  `VkSurfaceKHR` e gerenciamento do seu lifetime.
- OpenGL: criação/destruição de contexto, associação à thread, buffer
  swap, swap interval, compartilhamento, carregamento de funções
  (WGL no Win32; GLX/EGL no X11/Wayland).
- Direct3D 11/12 (Win32): expor handles e informações para a engine
  criar swapchains (DXGI).

**Renderer/RHI da engine (fora do Zigway):**

- Dispositivos, filas, command lists, pipelines, swapchains, frames.

O Zigway **nunca** implementará um renderer. Criar janelas nunca
exigirá Vulkan/OpenGL/Direct3D; bibliotecas gráficas só carregam sob
demanda da integração pedida.

## Estado por backend (quando implementado)

| Backend | Vulkan | OpenGL | Direct3D |
|---|---|---|---|
| Win32 | superfície Win32 | WGL | handles DXGI 11/12 |
| X11 | superfície Xlib | GLX/EGL | n/a |
| Wayland | superfície Wayland | EGL | n/a |

Nenhum suporte funcional é declarado até integração + testes por
combinação backend/API.
