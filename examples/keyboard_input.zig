// keyboard_input: imprime eventos de teclado/mouse e o estado de input.

const std = @import("std");
const zigway = @import("zigway");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var platform = try zigway.Platform.init(allocator, .{});
    defer platform.deinit();

    var window = try platform.createWindow(.{
        .width = 800,
        .height = 600,
        .title = "Zigway — keyboard_input",
    });
    defer window.deinit();

    std.debug.print("zigway: pressione teclas, mova o mouse, Esc sai.\n", .{});
    while (!window.shouldClose()) {
        platform.pollEvents();
        while (platform.nextEvent()) |event| {
            switch (event) {
                .close => window.requestClose(),
                .key_down => |e| {
                    std.debug.print("key_down: {t} repeat={}\n", .{ e.key, e.repeat });
                    if (e.key == .escape) window.requestClose();
                },
                .key_up => |e| {
                    std.debug.print("key_up: {t}\n", .{e.key});
                },
                .pointer_move => |e| {
                    std.debug.print("move: {d},{d}\n", .{ e.x, e.y });
                },
                .pointer_button => |e| {
                    std.debug.print("button: {t} pressed={}\n", .{ e.button, e.pressed });
                },
                .scroll => |e| {
                    std.debug.print("scroll: dx={d} dy={d}\n", .{ e.dx, e.dy });
                },
                else => {},
            }
        }
        if (platform.inputState().isKeyDown(.escape)) window.requestClose();
    }
}
