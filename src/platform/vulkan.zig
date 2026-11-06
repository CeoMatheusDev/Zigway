// Zigway Platform: declarações de ABI Vulkan (sem @cImport).
//
// As funções Vulkan são carregadas em runtime, seguindo o mesmo padrão de
// libwayland-client (Wayland) e libXrandr (X11). Nenhum símbolo é
// vinculado em tempo de build: criar janelas nunca exige Vulkan.
//
// Estratégia de carregamento:
//   1. `vkGetInstanceProcAddr` é carregado direto da libvulkan.
//   2. `vkCreate*SurfaceKHR` são obtidos via
//      `vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR")` etc.,
//      já que são funções de extensão dependentes da instância.
//   3. `vkDestroySurfaceKHR` é opcional (resolvido do loader, com fallback
//      por instância em `Lib.procAddr`).
//
// Carregador dinâmico (`DynLib`): `std.DynLib` nos alvos que o std 0.17.0
// suporta (ELF/dyld) e `LoadLibraryA`/`GetProcAddress` no Windows, onde o
// std não tem backend de `DynLib`. Alvos sem carregador retornam `null` em
// `Lib.load()` (Vulkan indisponível, sem falha de compilação).
//
// Tipos de handle: os handles Vulkan são ponteiros opacos. Handles
// não-dispatchable (ex.: `VkSurfaceKHR`) são representados por
// `?*anyopaque` (VK_NULL_HANDLE = null); handles dispatchable
// (`VkInstance`) por `*anyopaque`.

const std = @import("std");
const builtin = @import("builtin");

/// Handle dispatchable (VkInstance, VkDevice, ...). Nunca nulo nas funções
/// desta camada, exceto onde a API aceita `VK_NULL_HANDLE`.
pub const VkInstance = *anyopaque;

/// Handle não-dispatchable (VkSurfaceKHR, VkPhysicalDevice, ...).
/// `null` == VK_NULL_HANDLE.
pub const VkSurfaceKHR = ?*anyopaque;
pub const VkPhysicalDevice = ?*anyopaque;
pub const VkDevice = ?*anyopaque;

/// `VkAllocationCallbacks*` (sempre null nesta camada).
pub const VkAllocationCallbacks = opaque {};

/// Resultado de chamadas Vulkan. 0 == VK_SUCCESS.
pub const VkResult = i32;

/// Tipo de estrutura Vulkan (usado no campo sType das create infos).
pub const VkStructureType = i32;

/// Flags genéricas do Vulkan.
pub const VkFlags = u32;

/// Resultado VK_SUCCESS.
pub const VK_SUCCESS: VkResult = 0;

/// Extensão de instância exigida por cada backend (nome UTF-8).
pub const extension_xlib = "VK_KHR_xlib_surface";
pub const extension_win32 = "VK_KHR_win32_surface";
pub const extension_wayland = "VK_KHR_wayland_surface";

// --- Estruturas de criação de superfície (layout de vulkan/vulkan.h) ---

/// VkXlibSurfaceCreateInfoKHR (VK_KHR_xlib_surface).
///   sType, pNext, flags, dpy (Display*), window (Window/XID)
pub const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    flags: VkFlags,
    dpy: ?*anyopaque, // Display*
    window: c_ulong, // Window (XID)
};

/// VkWin32SurfaceCreateInfoKHR (VK_KHR_win32_surface).
///   sType, pNext, flags, hinstance (HINSTANCE), hwnd (HWND)
pub const VkWin32SurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    flags: VkFlags,
    hinstance: ?*anyopaque, // HINSTANCE
    hwnd: ?*anyopaque, // HWND
};

/// VkWaylandSurfaceCreateInfoKHR (VK_KHR_wayland_surface).
///   sType, pNext, flags, display (wl_display*), surface (wl_surface*)
pub const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    flags: VkFlags,
    display: ?*anyopaque, // wl_display*
    surface: ?*anyopaque, // wl_surface*
};

/// sType das create infos acima (VK_STRUCTURE_TYPE_*_SURFACE_CREATE_INFO_KHR).
pub const VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR: VkStructureType = 1000004000;
pub const VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR: VkStructureType = 1000009000;
pub const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR: VkStructureType = 1000005000;

/// VkExtensionProperties (extensionName[256] + specVersion).
pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

// --- Ponteiros de função Vulkan (PFN_*) ---

/// PFN_vkCreateXlibSurfaceKHR (via vkGetInstanceProcAddr).
pub const CreateXlibSurfaceKHRFn = *const fn (
    instance: VkInstance,
    pCreateInfo: *const VkXlibSurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkCreateWin32SurfaceKHR (via vkGetInstanceProcAddr).
pub const CreateWin32SurfaceKHRFn = *const fn (
    instance: VkInstance,
    pCreateInfo: *const VkWin32SurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkCreateWaylandSurfaceKHR (via vkGetInstanceProcAddr).
pub const CreateWaylandSurfaceKHRFn = *const fn (
    instance: VkInstance,
    pCreateInfo: *const VkWaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkDestroySurfaceKHR.
pub const DestroySurfaceKHRFn = *const fn (
    instance: VkInstance,
    surface: VkSurfaceKHR,
    pAllocator: ?*const VkAllocationCallbacks,
) callconv(.c) void;

/// PFN_vkGetInstanceProcAddr.
pub const GetInstanceProcAddrFn = *const fn (
    instance: ?VkInstance,
    pName: [*:0]const u8,
) callconv(.c) ?*anyopaque;

/// PFN_vkEnumerateInstanceExtensionProperties.
pub const EnumerateInstanceExtensionPropertiesFn = *const fn (
    pLayerName: ?[*:0]const u8,
    pCount: *u32,
    pProperties: ?[*]VkExtensionProperties,
) callconv(.c) VkResult;

// --- Carregador dinâmico ---

/// O std 0.17.0 implementa `std.DynLib` somente para ELF e dyld.
const std_dynlib_supported = switch (builtin.os.tag) {
    .linux,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    .illumos,
    .macos,
    .ios,
    .tvos,
    .watchos,
    .visionos,
    .maccatalyst,
    .driverkit,
    => true,
    else => false,
};

/// `LoadLibraryA`/`GetProcAddress`/`FreeLibrary` do kernel32 (Windows).
/// Declarados manualmente, como todas as ABIs nativas do projeto.
const kernel32 = struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: *anyopaque) callconv(.c) c_int;
};

/// Carregador mínimo no Windows, com a mesma interface usada de
/// `std.DynLib` (`open`/`close`/`lookup`).
const WindowsDynLib = struct {
    handle: *anyopaque,

    fn open(path: [*:0]const u8) !WindowsDynLib {
        const handle = kernel32.LoadLibraryA(path) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    fn close(self: *WindowsDynLib) void {
        _ = kernel32.FreeLibrary(self.handle);
    }

    fn lookup(self: *WindowsDynLib, comptime T: type, name: [*:0]const u8) ?T {
        const addr = kernel32.GetProcAddress(self.handle, name) orelse return null;
        return @ptrCast(addr);
    }
};

/// Carregador dinâmico efetivo do alvo.
pub const DynLib = if (builtin.os.tag == .windows) WindowsDynLib else std.DynLib;

/// Alvos em que a libvulkan pode ser carregada em runtime.
pub const dynlib_supported = builtin.os.tag == .windows or std_dynlib_supported;

/// Nome da biblioteca Vulkan por sistema operacional.
pub fn libName() [:0]const u8 {
    return switch (builtin.os.tag) {
        .windows => "vulkan-1.dll",
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => "libvulkan.1.dylib",
        else => "libvulkan.so.1",
    };
}

/// Converte um ponteiro de símbolo (`?*anyopaque`) no tipo de função `T`.
/// Retorna `null` quando o símbolo não existe.
pub fn resolve(comptime T: type, raw: ?*anyopaque) ?T {
    const ptr = raw orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// A libvulkan carregada (dono do carregador dinâmico).
pub const Lib = struct {
    dyn: DynLib,
    get_instance_proc_addr: GetInstanceProcAddrFn,
    destroy_surface: ?DestroySurfaceKHRFn = null,
    enumerate_instance_extensions: ?EnumerateInstanceExtensionPropertiesFn = null,

    /// Carrega a libvulkan. Retorna `null` quando o alvo não tem
    /// carregador dinâmico, quando a biblioteca não existe ou quando
    /// `vkGetInstanceProcAddr` está ausente — nos três casos Vulkan é
    /// simplesmente indisponível (nunca erro de compilação).
    pub fn load() ?Lib {
        if (comptime !dynlib_supported) return null;

        var dyn = DynLib.open(libName()) catch return null;
        const get_proc = dyn.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") orelse {
            dyn.close();
            return null;
        };
        const destroy_surface = dyn.lookup(DestroySurfaceKHRFn, "vkDestroySurfaceKHR");
        const enumerate_instance_extensions = dyn.lookup(
            EnumerateInstanceExtensionPropertiesFn,
            "vkEnumerateInstanceExtensionProperties",
        );

        return .{
            .dyn = dyn,
            .get_instance_proc_addr = get_proc,
            .destroy_surface = destroy_surface,
            .enumerate_instance_extensions = enumerate_instance_extensions,
        };
    }

    /// Resolve um ponteiro de função via `vkGetInstanceProcAddr`.
    /// `instance` pode ser null para funções globais do loader.
    pub fn procAddr(self: *Lib, instance: ?VkInstance, name: [*:0]const u8) ?*anyopaque {
        return self.get_instance_proc_addr(instance, name);
    }

    /// `vkDestroySurfaceKHR` direto do loader (pode ser null).
    pub fn destroySurface(self: *Lib) ?DestroySurfaceKHRFn {
        return self.destroy_surface;
    }

    pub fn deinit(self: *Lib) void {
        if (comptime dynlib_supported) self.dyn.close();
    }
};

/// Enumera as extensões de instância suportadas pelo loader.
///
/// Ownership: os nomes são copiados para o alocador e devem ser liberados
/// com `freeInstanceExtensions`. Retorna slice vazia quando a função não
/// existe no loader (Vulkan antigo ou ausente).
pub fn enumerateInstanceExtensions(
    lib: *Lib,
    allocator: std.mem.Allocator,
) ![]const []const u8 {
    const enum_fn = lib.enumerate_instance_extensions orelse return allocator.alloc([]const u8, 0);

    var count: u32 = 0;
    var rc = enum_fn(null, &count, null);
    if (count == 0) {
        if (rc != VK_SUCCESS) return allocator.alloc([]const u8, 0);
        return allocator.alloc([]const u8, 0);
    }

    var props = try allocator.alloc(VkExtensionProperties, count);
    defer allocator.free(props);

    rc = enum_fn(null, &count, props.ptr);
    if (rc != VK_SUCCESS) return error.VulkanEnumerationFailed;

    const total: usize = @intCast(@min(count, props.len));
    const names = try allocator.alloc([]const u8, total);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| allocator.free(name);
        allocator.free(names);
    }
    for (props[0..total], 0..) |prop, i| {
        const len = std.mem.indexOfScalar(u8, &prop.extensionName, 0) orelse prop.extensionName.len;
        names[i] = try allocator.dupe(u8, prop.extensionName[0..len]);
        filled += 1;
    }
    return names[0..filled];
}

/// Libera o resultado de `enumerateInstanceExtensions`.
pub fn freeInstanceExtensions(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

test "VkResult success is zero" {
    try std.testing.expectEqual(@as(VkResult, 0), VK_SUCCESS);
}

test "libName returns non-empty string" {
    const name = libName();
    try std.testing.expect(name.len > 0);
}

test "handles nulos representam VK_NULL_HANDLE" {
    const surface: VkSurfaceKHR = null;
    try std.testing.expect(surface == null);
}

test "create info mantem o layout declarado" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VkXlibSurfaceCreateInfoKHR));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VkWin32SurfaceCreateInfoKHR));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(VkWaylandSurfaceCreateInfoKHR));
}

test "load sem libvulkan no sistema retorna null ou uma Lib valida" {
    // Nao presume a presenca de libvulkan: so garante que a funcao nao
    // tem comportamento indefinido e que `deinit` e seguro quando carrega.
    if (Lib.load()) |lib_value| {
        var lib = lib_value;
        defer lib.deinit();
        try std.testing.expect(lib.procAddr(null, "vkGetInstanceProcAddr") != null);
    }
}
