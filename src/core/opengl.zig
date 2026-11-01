// Zigway Core: integração OpenGL (v0.4.x).
//
// Responsabilidades do Zigway (integração nativa da janela):
//   - OpenGL: criação/destruição de contexto, associação à thread,
//     buffer swap, swap interval, carregamento de funções
//     (WGL no Win32; GLX/EGL no X11/Wayland).
//
// O Zigway nunca implementa um renderer. Criar janelas nunca exige
// OpenGL; bibliotecas gráficas só carregam sob demanda da integração
// pedida.
//
// Sem @cImport, headers C ou pacotes externos: a ABI EGL/WGL/GLX é
// declarada manualmente em src/platform/ e carregada via dlopen em
// runtime (igual a libX11/libwayland/libXrandr/libvulkan).

const std = @import("std");

/// API gráfica OpenGL.
pub const OpenGLAPI = enum {
    opengl_es,
    opengl,

    pub const count: usize = @typeInfo(OpenGLAPI).@"enum".field_names.len;
};

/// Handle de contexto OpenGL. O backend detém o lifetime;
/// `destroyOpenGLContext` libera. O handle é nulo quando não há
//  contexto associado.
pub const OpenGLContext = struct {
    native: *anyopaque,

    /// true quando o handle é nulo (sem contexto associado).
    pub fn isNull(self: OpenGLContext) bool {
        return self.native == null;
    }
};

/// Erros da integração OpenGL.
pub const OpenGLError = error{
    /// A API OpenGL solicitada não é suportada pelo backend ativo.
    UnsupportedAPI,
    /// A biblioteca OpenGL/EGL/WGL/GLX não está disponível.
    OpenGLUnavailable,
    /// Falha ao criar o contexto.
    ContextCreationFailed,
    /// Janela inválida ou não pertencente a esta Platform.
    InvalidWindow,
    /// A Platform já foi encerrada.
    PlatformClosed,
};

/// Capacidades OpenGL do backend ativo.
pub const OpenGLCapabilities = struct {
    /// O backend pode criar contextos OpenGL (WGL/GLX/EGL).
    opengl_context: bool = false,
};

test "OpenGLCapabilities defaults are all false" {
    const caps: OpenGLCapabilities = .{};
    try std.testing.expect(!caps.opengl_context);
}
