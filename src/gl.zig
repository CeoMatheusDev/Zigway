// Zigway OpenGL: contexto OpenGL via EGL, carregado em runtime.
//
// Escopo: cria e gerencia o contexto/superficie OpenGL de UMA janela.
// NAO e um renderer: o Zigway continua sem dispositivo, pipeline ou
// comandos de desenho (ver docs/GRAPHICS.md). A aplicacao carrega as
// funcoes GL com `Context.getProc` e desenha como quiser.
//
// Sem dependencia de link: `libEGL.so.1` (ou `libEGL.so`) e procurada em
// runtime com `std.DynLib`; a ABI do EGL e declarada manualmente (sem
// @cImport). Sem a biblioteca, `init` retorna `error.GraphicsUnavailable`.
//
// Backends: X11 (EGL_PLATFORM_X11). Os demais retornam
// `error.NotImplemented` (via `Window.nativeHandle`).
//
// Threading: afinidade com a thread que chama `makeCurrent`. Um contexto
// so pode estar ativo em uma thread por vez.
//
// Limitacao desta versao: UM `Context` por `Platform`. `deinit` chama
// `eglTerminate` no `EGLDisplay`, o que invalida outros contextos criados
// sobre a mesma conexao.
//
// Ordem de destruicao OBRIGATORIA: `Context.deinit` antes de
// `Window.deinit` e de `Platform.deinit` (o EGLDisplay precisa ser
// terminado antes do `XCloseDisplay`).

const std = @import("std");
const native = @import("core/native.zig");
const window_mod = @import("window.zig");
const platform_mod = @import("platform/platform.zig");

pub const Window = window_mod.Window;

pub const Options = struct {
    /// Versao do OpenGL pedida (desktop GL).
    major: u8 = 3,
    minor: u8 = 3,
    /// Perfil core. `false` deixa o driver escolher (compatibilidade).
    core_profile: bool = true,
    /// Bits minimos de depth buffer (0 = sem exigencia).
    depth_bits: u8 = 0,
    /// Sincronismo vertical aplicado em `makeCurrent` (intervalo 1).
    vsync: bool = true,
};

// --- ABI do EGL (Khronos egl.h), declarada manualmente ---

const EGLDisplay = ?*anyopaque;
const EGLConfig = ?*anyopaque;
const EGLContext = ?*anyopaque;
const EGLSurface = ?*anyopaque;
const EGLBoolean = c_uint;
const EGLint = i32;

const EGL_NONE: EGLint = 0x3038;
const EGL_SURFACE_TYPE: EGLint = 0x3033;
const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
const EGL_NATIVE_VISUAL_ID: EGLint = 0x302E;
const EGL_RED_SIZE: EGLint = 0x3024;
const EGL_GREEN_SIZE: EGLint = 0x3023;
const EGL_BLUE_SIZE: EGLint = 0x3022;
const EGL_ALPHA_SIZE: EGLint = 0x3021;
const EGL_DEPTH_SIZE: EGLint = 0x3025;
const EGL_WINDOW_BIT: EGLint = 0x0004;
const EGL_OPENGL_BIT: EGLint = 0x0008;
const EGL_OPENGL_API: c_uint = 0x30A2;
const EGL_PLATFORM_X11_KHR: c_uint = 0x31D5;
const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: EGLint = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: EGLint = 0x0001;

const GetDisplayFn = *const fn (?*anyopaque) callconv(.c) EGLDisplay;
const GetPlatformDisplayFn = *const fn (c_uint, ?*anyopaque, ?[*]const isize) callconv(.c) EGLDisplay;
const InitializeFn = *const fn (EGLDisplay, *EGLint, *EGLint) callconv(.c) EGLBoolean;
const TerminateFn = *const fn (EGLDisplay) callconv(.c) EGLBoolean;
const BindApiFn = *const fn (c_uint) callconv(.c) EGLBoolean;
const GetConfigsFn = *const fn (EGLDisplay, ?[*]EGLConfig, EGLint, *EGLint) callconv(.c) EGLBoolean;
const GetConfigAttribFn = *const fn (EGLDisplay, EGLConfig, EGLint, *EGLint) callconv(.c) EGLBoolean;
const CreateWindowSurfaceFn = *const fn (EGLDisplay, EGLConfig, c_ulong, ?[*]const EGLint) callconv(.c) EGLSurface;
const CreateContextFn = *const fn (EGLDisplay, EGLConfig, EGLContext, ?[*]const EGLint) callconv(.c) EGLContext;
const MakeCurrentFn = *const fn (EGLDisplay, EGLSurface, EGLSurface, EGLContext) callconv(.c) EGLBoolean;
const SwapBuffersFn = *const fn (EGLDisplay, EGLSurface) callconv(.c) EGLBoolean;
const SwapIntervalFn = *const fn (EGLDisplay, EGLint) callconv(.c) EGLBoolean;
const DestroySurfaceFn = *const fn (EGLDisplay, EGLSurface) callconv(.c) EGLBoolean;
const DestroyContextFn = *const fn (EGLDisplay, EGLContext) callconv(.c) EGLBoolean;
const GetProcAddressFn = *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque;

fn sym(dyn: *std.DynLib, comptime T: type, name: [:0]const u8) error{GraphicsUnavailable}!T {
    return dyn.lookup(T, name) orelse error.GraphicsUnavailable;
}

/// Handle e simbolos de libEGL. Mantido vivo enquanto o `Context` existir.
const Lib = struct {
    dyn: std.DynLib,
    get_display: GetDisplayFn,
    /// Opcional (EGL 1.5): preferido quando existe.
    get_platform_display: ?GetPlatformDisplayFn,
    initialize: InitializeFn,
    terminate: TerminateFn,
    bind_api: BindApiFn,
    get_configs: GetConfigsFn,
    get_config_attrib: GetConfigAttribFn,
    create_window_surface: CreateWindowSurfaceFn,
    create_context: CreateContextFn,
    make_current: MakeCurrentFn,
    swap_buffers: SwapBuffersFn,
    swap_interval: SwapIntervalFn,
    destroy_surface: DestroySurfaceFn,
    destroy_context: DestroyContextFn,
    get_proc_address: GetProcAddressFn,

    fn load() error{GraphicsUnavailable}!Lib {
        var dyn = std.DynLib.open("libEGL.so.1") catch blk: {
            break :blk std.DynLib.open("libEGL.so") catch return error.GraphicsUnavailable;
        };
        errdefer dyn.close();

        const get_display = try sym(&dyn, GetDisplayFn, "eglGetDisplay");
        const get_platform_display = dyn.lookup(GetPlatformDisplayFn, "eglGetPlatformDisplay");
        const initialize = try sym(&dyn, InitializeFn, "eglInitialize");
        const terminate = try sym(&dyn, TerminateFn, "eglTerminate");
        const bind_api = try sym(&dyn, BindApiFn, "eglBindAPI");
        const get_configs = try sym(&dyn, GetConfigsFn, "eglGetConfigs");
        const get_config_attrib = try sym(&dyn, GetConfigAttribFn, "eglGetConfigAttrib");
        const create_window_surface = try sym(&dyn, CreateWindowSurfaceFn, "eglCreateWindowSurface");
        const create_context = try sym(&dyn, CreateContextFn, "eglCreateContext");
        const make_current = try sym(&dyn, MakeCurrentFn, "eglMakeCurrent");
        const swap_buffers = try sym(&dyn, SwapBuffersFn, "eglSwapBuffers");
        const swap_interval = try sym(&dyn, SwapIntervalFn, "eglSwapInterval");
        const destroy_surface = try sym(&dyn, DestroySurfaceFn, "eglDestroySurface");
        const destroy_context = try sym(&dyn, DestroyContextFn, "eglDestroyContext");
        const get_proc_address = try sym(&dyn, GetProcAddressFn, "eglGetProcAddress");

        return .{
            .dyn = dyn,
            .get_display = get_display,
            .get_platform_display = get_platform_display,
            .initialize = initialize,
            .terminate = terminate,
            .bind_api = bind_api,
            .get_configs = get_configs,
            .get_config_attrib = get_config_attrib,
            .create_window_surface = create_window_surface,
            .create_context = create_context,
            .make_current = make_current,
            .swap_buffers = swap_buffers,
            .swap_interval = swap_interval,
            .destroy_surface = destroy_surface,
            .destroy_context = destroy_context,
            .get_proc_address = get_proc_address,
        };
    }

    fn deinit(self: *Lib) void {
        self.dyn.close();
    }
};

/// Contexto OpenGL (EGL) de uma janela.
pub const Context = struct {
    lib: Lib,
    display: EGLDisplay,
    surface: EGLSurface,
    context: EGLContext,
    vsync: bool,

    /// Cria o contexto e a superficie da janela. O contexto NAO fica
    /// ativo: chame `makeCurrent` na thread que vai desenhar.
    pub fn init(window: Window, options: Options) !Context {
        const handle = try window.nativeHandle();
        switch (handle) {
            .x11 => |h| return initX11(h, options),
        }
    }

    fn initX11(h: native.NativeHandle.X11, options: Options) !Context {
        var lib = try Lib.load();
        errdefer lib.deinit();

        var display: EGLDisplay = null;
        if (lib.get_platform_display) |f| display = f(EGL_PLATFORM_X11_KHR, h.display, null);
        if (display == null) display = lib.get_display(h.display);
        if (display == null) return error.GraphicsContextFailed;

        var egl_major: EGLint = 0;
        var egl_minor: EGLint = 0;
        if (lib.initialize(display, &egl_major, &egl_minor) == 0) return error.GraphicsContextFailed;
        errdefer _ = lib.terminate(display);

        if (lib.bind_api(EGL_OPENGL_API) == 0) return error.GraphicsContextFailed;

        const config = try chooseConfig(&lib, display, h.visual_id, options);

        const surface = lib.create_window_surface(display, config, h.window, null);
        if (surface == null) return error.GraphicsContextFailed;
        errdefer _ = lib.destroy_surface(display, surface);

        const profile: EGLint = if (options.core_profile) EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT else 0;
        const attribs = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION,
            options.major,
            EGL_CONTEXT_MINOR_VERSION,
            options.minor,
            EGL_CONTEXT_OPENGL_PROFILE_MASK,
            profile,
            EGL_NONE,
        };
        const context = lib.create_context(display, config, null, &attribs);
        if (context == null) return error.GraphicsContextFailed;

        return .{
            .lib = lib,
            .display = display,
            .surface = surface,
            .context = context,
            .vsync = options.vsync,
        };
    }

    /// Escolhe a configuracao de superficie compativel com o visual da
    /// janela (obrigatorio no X11), com suporte a janela + OpenGL e
    /// RGB >= 8 bits. Entre as candidatas, prefere menos excesso de depth
    /// e menos alpha.
    fn chooseConfig(
        lib: *const Lib,
        display: EGLDisplay,
        visual_id: c_ulong,
        options: Options,
    ) !EGLConfig {
        var configs: [256]EGLConfig = undefined;
        var count: EGLint = 0;
        if (lib.get_configs(display, &configs, 256, &count) == 0) return error.GraphicsContextFailed;
        if (count <= 0) return error.GraphicsContextFailed;

        var best: EGLConfig = null;
        var best_score: i64 = std.math.maxInt(i64);
        const total: usize = @intCast(@min(count, 256));
        for (configs[0..total]) |cfg| {
            const surface_type = attrib(lib, display, cfg, EGL_SURFACE_TYPE) orelse continue;
            const renderable = attrib(lib, display, cfg, EGL_RENDERABLE_TYPE) orelse continue;
            const native_visual = attrib(lib, display, cfg, EGL_NATIVE_VISUAL_ID) orelse continue;
            const red = attrib(lib, display, cfg, EGL_RED_SIZE) orelse continue;
            const green = attrib(lib, display, cfg, EGL_GREEN_SIZE) orelse continue;
            const blue = attrib(lib, display, cfg, EGL_BLUE_SIZE) orelse continue;
            const alpha = attrib(lib, display, cfg, EGL_ALPHA_SIZE) orelse continue;
            const depth = attrib(lib, display, cfg, EGL_DEPTH_SIZE) orelse continue;

            if ((surface_type & EGL_WINDOW_BIT) == 0) continue;
            if ((renderable & EGL_OPENGL_BIT) == 0) continue;
            if (@as(c_ulong, @intCast(native_visual)) != visual_id) continue;
            if (red < 8 or green < 8 or blue < 8) continue;
            if (depth < options.depth_bits) continue;

            const score: i64 = @as(i64, depth - options.depth_bits) * 16 + alpha;
            if (score < best_score) {
                best_score = score;
                best = cfg;
            }
        }
        if (best == null) return error.GraphicsContextFailed;
        return best;
    }

    fn attrib(lib: *const Lib, display: EGLDisplay, cfg: EGLConfig, name: EGLint) ?EGLint {
        var value: EGLint = 0;
        if (lib.get_config_attrib(display, cfg, name, &value) == 0) return null;
        return value;
    }

    /// Ativa o contexto na thread atual (e aplica o vsync pedido).
    pub fn makeCurrent(self: *Context) !void {
        if (self.lib.make_current(self.display, self.surface, self.surface, self.context) == 0) {
            return error.GraphicsContextFailed;
        }
        const interval: EGLint = if (self.vsync) 1 else 0;
        // Falha no swap interval nao e fatal: o driver pode ignora-lo.
        _ = self.lib.swap_interval(self.display, interval);
    }

    /// Desativa o contexto na thread atual.
    pub fn releaseCurrent(self: *Context) void {
        _ = self.lib.make_current(self.display, null, null, null);
    }

    /// Apresenta o back buffer.
    pub fn swapBuffers(self: *Context) !void {
        if (self.lib.swap_buffers(self.display, self.surface) == 0) {
            return error.GraphicsContextFailed;
        }
    }

    /// Altera o intervalo de swap (0 = sem vsync). O contexto precisa
    /// estar ativo nesta thread.
    pub fn setSwapInterval(self: *Context, interval: i32) !void {
        if (self.lib.swap_interval(self.display, interval) == 0) {
            return error.GraphicsContextFailed;
        }
        self.vsync = interval != 0;
    }

    /// Endereco de uma funcao OpenGL (ou null). Use `getProc` para obter
    /// o ponteiro ja tipado.
    pub fn getProcAddress(self: *const Context, name: [*:0]const u8) ?*const anyopaque {
        return self.lib.get_proc_address(name);
    }

    /// Funcao OpenGL tipada: `T` deve ser um tipo de ponteiro de funcao
    /// com `callconv(.c)`.
    pub fn getProc(self: *const Context, comptime T: type, name: [*:0]const u8) ?T {
        const addr = self.getProcAddress(name) orelse return null;
        return @ptrCast(@alignCast(addr));
    }

    /// Destroi contexto e superficie, termina o EGLDisplay e descarrega a
    /// libEGL. Chamar ANTES de `Window.deinit`/`Platform.deinit`.
    pub fn deinit(self: *Context) void {
        _ = self.lib.make_current(self.display, null, null, null);
        _ = self.lib.destroy_context(self.display, self.context);
        _ = self.lib.destroy_surface(self.display, self.surface);
        _ = self.lib.terminate(self.display);
        self.lib.deinit();
        self.display = null;
        self.surface = null;
        self.context = null;
    }
};

test "Options: padroes" {
    const o: Options = .{};
    try std.testing.expectEqual(@as(u8, 3), o.major);
    try std.testing.expectEqual(@as(u8, 3), o.minor);
    try std.testing.expect(o.core_profile);
    try std.testing.expect(o.vsync);
    try std.testing.expectEqual(@as(u8, 0), o.depth_bits);
}

test "init sem handle nativo (backend null) retorna NotImplemented" {
    var plat = try platform_mod.Platform.init(std.testing.allocator, .{ .backend = .null_backend });
    defer plat.deinit();
    var w = try plat.createWindow(.{ .width = 64, .height = 64 });
    defer w.deinit();
    try std.testing.expectError(error.NotImplemented, Context.init(w, .{}));
}
