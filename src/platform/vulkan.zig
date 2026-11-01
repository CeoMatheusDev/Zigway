// Zigway Platform: declarações de ABI Vulkan (sem @cImport).
//
// As funções Vulkan são carregadas em runtime via std.DynLib (libvulkan),
// seguindo o mesmo padrão de libwayland-client (Wayland) e libXrandr
// (X11). Nenhum símbolo é vinculado em tempo de build.
//
// Estratégia de carregamento:
//   1. vkGetInstanceProcAddr e vkDestroySurfaceKHR são carregados direto
//      da libvulkan.
//   2. vkCreate*SurfaceKHR são obtidos via vkGetInstanceProcAddr(instance,
//      "vkCreateXlibSurfaceKHR") etc., já que são funções de extensão
//      dependentes da instância.
//
// Tipos opacos do Vulkan:
//   VkInstance, VkSurfaceKHR, VkPhysicalDevice, VkDevice,
//   VkAllocationCallbacks — ponteiros opacos.
//   VkResult — enum de inteiros (0 = VK_SUCCESS).
//   VkStructureType — enum de inteiros.
//   VkFlags — uint32_t.

const std = @import("std");
const builtin = @import("builtin");

/// Handle opaco do Vulkan.
pub const VkInstance = opaque {};
pub const VkSurfaceKHR = opaque {};
pub const VkPhysicalDevice = opaque {};
pub const VkDevice = opaque {};
pub const VkAllocationCallbacks = opaque {};

/// Resultado de chamadas Vulkan. 0 == VK_SUCCESS.
pub const VkResult = i32;

/// Tipo de estrutura Vulkan (usado no campo sType das create infos).
pub const VkStructureType = i32;

/// Flags genéricas do Vulkan.
pub const VkFlags = u32;

/// Resultado VK_SUCCESS.
pub const VK_SUCCESS: VkResult = 0;

// --- Estruturas de criação de superfície (layout conferido contra vulkan/vulkan.h) ---

/// VkXlibSurfaceCreateInfoKHR (VK_KHR_xlib_surface).
///   sType, pNext, flags, window (Window), dpy (Display*)
pub const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    flags: VkFlags,
    dpy: ?*anyopaque, // Display*
    window: usize, // Window (c_ulong -> usize em x86_64)
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

// --- Estrutura para enumeração de extensões de instância ---

/// VkExtensionProperties (layout: extensionName[256], specVersion).
pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

// --- Ponteiros de função Vulkan (PFN_*) ---

/// PFN_vkCreateXlibSurfaceKHR (obtido via vkGetInstanceProcAddr).
pub const CreateXlibSurfaceKHRFn = *const fn (
    instance: *VkInstance,
    pCreateInfo: *const VkXlibSurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkCreateWin32SurfaceKHR (obtido via vkGetInstanceProcAddr).
pub const CreateWin32SurfaceKHRFn = *const fn (
    instance: *VkInstance,
    pCreateInfo: *const VkWin32SurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkCreateWaylandSurfaceKHR (obtido via vkGetInstanceProcAddr).
pub const CreateWaylandSurfaceKHRFn = *const fn (
    instance: *VkInstance,
    pCreateInfo: *const VkWaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const VkAllocationCallbacks,
    pSurface: *VkSurfaceKHR,
) callconv(.c) VkResult;

/// PFN_vkDestroySurfaceKHR.
pub const DestroySurfaceKHRFn = *const fn (
    instance: *VkInstance,
    surface: VkSurfaceKHR,
    pAllocator: ?*const VkAllocationCallbacks,
) callconv(.c) void;

/// PFN_vkGetInstanceProcAddr.
pub const GetInstanceProcAddrFn = *const fn (
    instance: *VkInstance,
    pName: [*]const u8,
) callconv(.c) ?*anyopaque;

/// PFN_vkEnumerateInstanceExtensionProperties.
pub const EnumerateInstanceExtensionPropertiesFn = *const fn (
    pLayerName: ?*const u8,
    pCount: *u32,
    pProperties: ?*VkExtensionProperties,
) callconv(.c) VkResult;

// --- Símbolos da libvulkan (carregados via std.DynLib) ---

/// Nome da biblioteca Vulkan por sistema operacional.
pub fn libName() []const u8 {
    return if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1";
}

/// A libvulkan carregada (dono do std.DynLib).
pub const Lib = struct {
    dyn: std.DynLib,
    get_instance_proc_addr: GetInstanceProcAddrFn,
    destroy_surface: ?DestroySurfaceKHRFn,
    enumerate_instance_extensions: ?EnumerateInstanceExtensionPropertiesFn,

    /// Carrega a libvulkan. Retorna null se a biblioteca ou algum
    /// símbolo essencial não existir.
    pub fn load() ?Lib {
        const dyn = std.DynLib.open(libName()) catch return null;

        const get_proc = dyn.lookup(GetInstanceProcAddrFn, "vkGetInstanceProcAddr") catch {
            dyn.close();
            return null;
        };

        const destroy_surface = dyn.lookup(DestroySurfaceKHRFn, "vkDestroySurfaceKHR") catch null;
        const enumerate_instance_extensions = dyn.lookup(
            EnumerateInstanceExtensionPropertiesFn,
            "vkEnumerateInstanceExtensionProperties",
        ) catch null;

        return .{
            .dyn = dyn,
            .get_instance_proc_addr = get_proc,
            .destroy_surface = destroy_surface,
            .enumerate_instance_extensions = enumerate_instance_extensions,
        };
    }

    /// Resolve um ponteiro de função de extensão via vkGetInstanceProcAddr.
    /// `instance` pode ser null para funções que não dependem de instância.
    pub fn procAddr(self: *Lib, instance: ?*VkInstance, name: []const u8) ?*anyopaque {
        const inst = instance orelse null;
        return self.get_instance_proc_addr(inst, name);
    }

    pub fn deinit(self: *Lib) void {
        self.dyn.close();
    }
};

/// Enumeração de extensões de instância Vulkan. Retorna a lista de nomes
/// de extensão suportadas pelo loader, ou um slice vazio se a função
/// não estiver disponível.
pub fn enumerateInstanceExtensions(
    lib: *Lib,
    allocator: std.mem.Allocator,
) ![][]const u8 {
    const enum_fn = lib.enumerate_instance_extensions orelse return allocator.alloc([]const u8, 0);

    var count: u32 = 0;
    const rc = enum_fn(null, &count, null);
    if (rc != VK_SUCCESS and count == 0) return allocator.alloc([]const u8, 0);

    var props: []VkExtensionProperties = try allocator.alloc(VkExtensionProperties, @intCast(count));
    defer allocator.free(props);

    const rc2 = enum_fn(null, &count, props);
    if (rc2 != VK_SUCCESS) return allocator.alloc([]const u8, 0);

    var names: [][]const u8 = try allocator.alloc([]const u8, @as(usize, @intCast(count)));
    var i: usize = 0;
    while (i < @as(usize, @intCast(count))) : (i += 1) {
        // extensionName é um array de 256 bytes terminado em zero.
        const len = std.mem.indexOf(u8, &props[i].extensionName, 0) orelse 256;
        names[i] = props[i].extensionName[0..len];
    }

    return names;
}

test "VkResult success is zero" {
    try std.testing.expectEqual(@as(VkResult, 0), VK_SUCCESS);
}

test "libName returns non-empty string" {
    const name = libName();
    try std.testing.expect(name.len > 0);
}
