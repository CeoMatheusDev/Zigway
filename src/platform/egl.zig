// Zigway Platform: declarações de ABI EGL (sem @cImport).
//
// A libEGL é carregada em runtime via std.DynLib, seguindo o mesmo
// padrão de libwayland-client (Wayland) e libvulkan (Vulkan). Nenhum
// símbolo é vinculado em tempo de build.
//
// EGL é usado tanto por X11 (via GLX/EGL) quanto por Wayland (via EGL)
// para criar contextos OpenGL.
//
// Tipos opacos do EGL:
//   EGLDisplay, EGLSurface, EGLContext, EGLConfig — ponteiros opacos.
//   EGLint, EGLBoolean, EGLenum — inteiros.
//
// Funções:
//   eglGetDisplay, eglInitialize, eglTerminate,
//   eglChooseConfig, eglCreateContext, eglDestroyContext,
//   eglCreateWindowSurface, eglDestroySurface, eglMakeCurrent,
//   eglSwapBuffers, eglSwapInterval, eglQueryString,
//   eglGetProcAddress.

const std = @import("std");
const builtin = @import("builtin");

/// Handle opaco do EGL.
pub const EGLDisplay = opaque {};
pub const EGLSurface = opaque {};
pub const EGLContext = opaque {};
pub const EGLConfig = opaque {};

/// Tipo EGLint (int32_t).
pub const EGLint = i32;
/// Tipo EGLBoolean (unsigned char).
pub const EGLBoolean = u8;
/// Tipo EGLenum (unsigned int).
pub const EGLEnum = u32;

/// EGL_TRUE / EGL_FALSE.
pub const EGL_TRUE: EGLBoolean = 1;
pub const EGL_FALSE: EGLBoolean = 0;

/// EGL_NONE (sentinel de fim de lista de atributos).
pub const EGL_NONE: EGLint = 0x3038;

/// EGL_DEFAULT_DISPLAY.
pub const EGL_DEFAULT_DISPLAY: EGLDisplay = @ptrCast(0);

// --- Atributos de configuração (valores comuns de egl.h) ---

pub const EGL_RED_SIZE: EGLint = 0x3024;
pub const EGL_GREEN_SIZE: EGLint = 0x3025;
pub const EGL_BLUE_SIZE: EGLint = 0x3026;
pub const EGL_ALPHA_SIZE: EGLint = 0x3027;
pub const EGL_DEPTH_SIZE: EGLint = 0x3022;
pub const EGL_STENCIL_SIZE: EGLint = 0x3023;
pub const EGL_SAMPLE_BUFFERS: EGLint = 0x3032;
pub const EGL_SAMPLES: EGLint = 0x3031;
pub const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
pub const EGL_SURFACE_TYPE: EGLint = 0x3033;
pub const EGL_CONFORMANT: EGLint = 0x3042;

/// EGL_OPENGL_BIT / EGL_OPENGL_ES_BIT.
pub const EGL_OPENGL_BIT: EGLEnum = 0x0001;
pub const EGL_OPENGL_ES_BIT: EGLEnum = 0x0002;

/// EGL_WINDOW_BIT.
pub const EGL_WINDOW_BIT: EGLEnum = 0x0004;

// --- Versões de API de contexto ---

pub const EGL_OPENGL_API: EGLEnum = 0x30A0;
pub const EGL_OPENGL_ES_API: EGLEnum = 0x30A1;

// --- Ponteiros de função EGL (PFNEGL*) ---

pub const GetDisplayFn = *const fn (*anyopaque) callconv(.c) EGLDisplay;
pub const InitializeFn = *const fn (EGLDisplay, *EGLint, *EGLint) callconv(.c) EGLBoolean;
pub const TerminateFn = *const fn (EGLDisplay) callconv(.c) EGLBoolean;
pub const ChooseConfigFn = *const fn (
    EGLDisplay,
    *const EGLint,
    *EGLConfig,
    EGLint,
    *EGLint,
) callconv(.c) EGLBoolean;
pub const CreateContextFn = *const fn (
    EGLDisplay,
    EGLConfig,
    EGLContext,
    *const EGLint,
) callconv(.c) EGLContext;
pub const DestroyContextFn = *const fn (EGLDisplay, EGLContext) callconv(.c) EGLBoolean;
pub const CreateWindowSurfaceFn = *const fn (
    EGLDisplay,
    EGLConfig,
    *anyopaque, // native window
    *const EGLint,
) callconv(.c) EGLSurface;
pub const DestroySurfaceFn = *const fn (EGLDisplay, EGLSurface) callconv(.c) EGLBoolean;
pub const MakeCurrentFn = *const fn (
    EGLDisplay,
    EGLSurface,
    EGLSurface,
    EGLContext,
) callconv(.c) EGLBoolean;
pub const SwapBuffersFn = *const fn (EGLDisplay, EGLSurface) callconv(.c) EGLBoolean;
pub const SwapIntervalFn = *const fn (EGLDisplay, EGLint) callconv(.c) EGLBoolean;
pub const QueryStringFn = *const fn (EGLDisplay, EGLint) callconv(.c) [*]const u8;
pub const GetProcAddressFn = *const fn ([*]const u8) callconv(.c) ?*anyopaque;

// --- Símbolos da libEGL (carregados via std.DynLib) ---

/// Conjunto de símbolos EGL que um backend pode carregar.
pub const Symbols = struct {
    get_display: ?GetDisplayFn,
    initialize: ?InitializeFn,
    terminate: ?TerminateFn,
    choose_config: ?ChooseConfigFn,
    create_context: ?CreateContextFn,
    destroy_context: ?DestroyContextFn,
    create_window_surface: ?CreateWindowSurfaceFn,
    destroy_surface: ?DestroySurfaceFn,
    make_current: ?MakeCurrentFn,
    swap_buffers: ?SwapBuffersFn,
    swap_interval: ?SwapIntervalFn,
    query_string: ?QueryStringFn,
    get_proc_address: ?GetProcAddressFn,
};

/// Nome da biblioteca EGL por sistema operacional.
pub fn libName() []const u8 {
    return if (builtin.os.tag == .windows) "libEGL.dll" else "libEGL.so.1";
}

/// A libEGL carregada (dono do std.DynLib).
pub const Lib = struct {
    dyn: std.DynLib,
    symbols: Symbols,

    /// Carrega a libEGL. Retorna null se a biblioteca ou algum símbolo
    /// essencial não existir.
    pub fn load() ?Lib {
        const dyn = std.DynLib.open(libName()) catch return null;

        const get_display = dyn.lookup(GetDisplayFn, "eglGetDisplay") catch {
            dyn.close();
            return null;
        };
        const initialize = dyn.lookup(InitializeFn, "eglInitialize") catch {
            dyn.close();
            return null;
        };
        const terminate = dyn.lookup(TerminateFn, "eglTerminate") catch {
            dyn.close();
            return null;
        };
        const choose_config = dyn.lookup(ChooseConfigFn, "eglChooseConfig") catch null;
        const create_context = dyn.lookup(CreateContextFn, "eglCreateContext") catch null;
        const destroy_context = dyn.lookup(DestroyContextFn, "eglDestroyContext") catch null;
        const create_window_surface = dyn.lookup(
            CreateWindowSurfaceFn,
            "eglCreateWindowSurface",
        ) catch null;
        const destroy_surface = dyn.lookup(DestroySurfaceFn, "eglDestroySurface") catch null;
        const make_current = dyn.lookup(MakeCurrentFn, "eglMakeCurrent") catch null;
        const swap_buffers = dyn.lookup(SwapBuffersFn, "eglSwapBuffers") catch null;
        const swap_interval = dyn.lookup(SwapIntervalFn, "eglSwapInterval") catch null;
        const query_string = dyn.lookup(QueryStringFn, "eglQueryString") catch null;
        const get_proc_address = dyn.lookup(GetProcAddressFn, "eglGetProcAddress") catch null;

        return .{
            .dyn = dyn,
            .symbols = .{
                .get_display = get_display,
                .initialize = initialize,
                .terminate = terminate,
                .choose_config = choose_config,
                .create_context = create_context,
                .destroy_context = destroy_context,
                .create_window_surface = create_window_surface,
                .destroy_surface = destroy_surface,
                .make_current = make_current,
                .swap_buffers = swap_buffers,
                .swap_interval = swap_interval,
                .query_string = query_string,
                .get_proc_address = get_proc_address,
            },
        };
    }

    pub fn deinit(self: *Lib) void {
        self.dyn.close();
    }
};

test "EGL_TRUE is 1 and EGL_FALSE is 0" {
    try std.testing.expectEqual(@as(EGLBoolean, 1), EGL_TRUE);
    try std.testing.expectEqual(@as(EGLBoolean, 0), EGL_FALSE);
}
