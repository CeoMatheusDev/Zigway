// Zigway Core: integração gráfica (v0.4.x).
//
// Responsabilidades do Zigway (integração nativa da janela):
//   - Vulkan: extensões de instância por backend, criação de VkSurfaceKHR
//     e gerenciamento do lifetime da superfície.
//   - OpenGL/Direct3D: declarados como APIs suportadas, sem superfície
//     nesta fase (futuros).
//
// O Zigway nunca implementa um renderer. Criar janelas nunca exige
// Vulkan/OpenGL/Direct3D; bibliotecas gráficas só carregam sob demanda
// da integração pedida.
//
// Sem @cImport, headers C ou pacotes externos: a ABI Vulkan é declarada
// manualmente em src/platform/vulkan.zig e carregada via dlopen em
// runtime (igual a libX11/libwayland/libXrandr nos backends).

const std = @import("std");
const types = @import("types.zig");

/// API gráfica suportada para integração de superfície/contexto.
pub const GraphicsAPI = enum {
    vulkan,
    opengl,
    direct3d,

    pub const count: usize = @typeInfo(GraphicsAPI).@"enum".field_names.len;
};

/// Handle de superfície Vulkan (VkSurfaceKHR). O backend detém o
/// lifetime; `destroyVulkanSurface` libera. O handle é nulo quando a
/// superfície não foi criada ou já foi destruída.
pub const VulkanSurface = struct {
    /// `VkSurfaceKHR` (VK_NULL_HANDLE == null).
    native: ?*anyopaque,

    /// true quando o handle é nulo (sem superfície associada).
    pub fn isNull(self: VulkanSurface) bool {
        return self.native == null;
    }
};

/// Erros da integração gráfica.
pub const GraphicsError = error{
    /// A API gráfica solicitada não é suportada pelo backend ativo.
    UnsupportedAPI,
    /// A biblioteca Vulkan não está disponível (libvulkan ausente ou
    /// símbolo necessário não encontrado).
    VulkanUnavailable,
    /// Falha ao criar a superfície (vkCreate*SurfaceKHR retornou erro).
    SurfaceCreationFailed,
    /// Janela inválida ou não pertencente a esta Platform.
    InvalidWindow,
    /// A Platform já foi encerrada.
    PlatformClosed,
};

/// Extensões de instância Vulkan exigidas por um backend: cada elemento
/// é um nome de extensão (UTF-8, terminado em zero).
pub const VulkanExtensions = []const []const u8;

/// Capacidades gráficas do backend ativo.
pub const GraphicsCapabilities = struct {
    /// O backend pode criar superfícies Vulkan.
    vulkan_surface: bool = false,
    /// O backend pode criar contextos OpenGL (WGL/GLX/EGL).
    opengl_context: bool = false,
    /// O backend expõe handles Direct3D/DXGI (Win32).
    direct3d_handle: bool = false,
};

test "GraphicsAPI enum is dense from zero" {
    try std.testing.expectEqual(@as(u32, 0), @backingInt(GraphicsAPI.vulkan));
    try std.testing.expectEqual(
        @as(u32, @intCast(GraphicsAPI.count - 1)),
        @backingInt(GraphicsAPI.direct3d),
    );
}

test "VulkanSurface nulo e seguro" {
    const empty: VulkanSurface = .{ .native = null };
    try std.testing.expect(empty.isNull());
}

test "GraphicsCapabilities defaults are all false" {
    const caps: GraphicsCapabilities = .{};
    try std.testing.expect(!caps.vulkan_surface);
    try std.testing.expect(!caps.opengl_context);
    try std.testing.expect(!caps.direct3d_handle);
}
