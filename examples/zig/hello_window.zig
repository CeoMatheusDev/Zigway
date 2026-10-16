// hello_window: abre uma janela e processa eventos ate fecha-la.

const std = @import("std");
const zigway = @import("zigway");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var platform = zigway.Platform.init(allocator, .{}) catch |err| {
        std.debug.print("zigway: Platform.init falhou: {t}\n", .{err});
        return err;
    };
    defer platform.deinit();

    std.debug.print("zigway: backend ativo: {t}\n", .{platform.backendKind()});

    var window = try platform.createWindow(.{
        .width = 1280,
        .height = 720,
        .title = "Zigway — hello_window",
    });
    defer window.deinit();

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
    }
    std.debug.print("zigway: encerrando.\n", .{});
}
