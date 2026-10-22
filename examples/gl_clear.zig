// gl_clear: abre uma janela X11, cria um contexto OpenGL 3.3 (EGL) e
// limpa a tela com uma cor que varia ate fechar (Esc ou fechar a janela).
//
// Requer libEGL e um driver OpenGL 3.3 core. Sem eles, encerra com erro
// claro. No Wayland, roda via XWayland (backend X11).

const std = @import("std");
const zigway = @import("zigway");

const GlClearColorFn = *const fn (f32, f32, f32, f32) callconv(.c) void;
const GlClearFn = *const fn (u32) callconv(.c) void;
const GlViewportFn = *const fn (i32, i32, i32, i32) callconv(.c) void;

const GL_COLOR_BUFFER_BIT: u32 = 0x4000;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var platform = zigway.Platform.init(allocator, .{ .backend = .x11 }) catch |err| {
        std.debug.print("zigway: Platform.init falhou: {t}\n", .{err});
        return err;
    };
    defer platform.deinit();

    var window = try platform.createWindow(.{
        .width = 960,
        .height = 540,
        .title = "Zigway — gl_clear",
    });
    defer window.deinit();

    var ctx = zigway.gl.Context.init(window, .{}) catch |err| {
        std.debug.print("zigway: contexto OpenGL indisponivel: {t}\n", .{err});
        return err;
    };
    // Declarado depois da janela: roda antes de `window.deinit()`.
    defer ctx.deinit();

    try ctx.makeCurrent();

    const gl_viewport = ctx.getProc(GlViewportFn, "glViewport") orelse return error.MissingGlSymbol;
    const gl_clear_color = ctx.getProc(GlClearColorFn, "glClearColor") orelse return error.MissingGlSymbol;
    const gl_clear = ctx.getProc(GlClearFn, "glClear") orelse return error.MissingGlSymbol;

    var frame: u32 = 0;
    while (!window.shouldClose()) {
        platform.pollEvents();
        while (platform.nextEvent()) |event| {
            switch (event) {
                .close => |e| {
                    if (e.window.eql(window.windowId())) window.requestClose();
                },
                .key_down => |e| {
                    if (e.key == .escape) window.requestClose();
                },
                else => {},
            }
        }

        const size = window.bufferSize();
        gl_viewport(0, 0, @intCast(size.width), @intCast(size.height));

        const t: f32 = @as(f32, @floatFromInt(frame % 240)) / 240.0;
        gl_clear_color(0.05 + 0.25 * t, 0.10, 0.30 + 0.30 * (1.0 - t), 1.0);
        gl_clear(GL_COLOR_BUFFER_BIT);
        try ctx.swapBuffers();
        frame +%= 1;
    }
    std.debug.print("zigway: encerrando apos {d} quadros.\n", .{frame});
}
