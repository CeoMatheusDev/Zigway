// multiple_windows: duas janelas independentes no mesmo Platform.
// Fechar qualquer uma (ou Esc) encerra o exemplo.

const std = @import("std");
const zigway = @import("zigway");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var platform = try zigway.Platform.init(allocator, .{});
    defer platform.deinit();

    var left = try platform.createWindow(.{
        .width = 640,
        .height = 480,
        .title = "Zigway — esquerda",
    });
    defer left.deinit();

    var right = try platform.createWindow(.{
        .width = 640,
        .height = 480,
        .title = "Zigway — direita",
    });
    defer right.deinit();

    std.debug.print("zigway: duas janelas ativas.\n", .{});
    while (!left.shouldClose() and !right.shouldClose()) {
        platform.pollEvents();
        while (platform.nextEvent()) |event| {
            switch (event) {
                .close => |e| {
                    if (e.window.eql(left.windowId())) left.requestClose();
                    if (e.window.eql(right.windowId())) right.requestClose();
                },
                .key_down => |e| {
                    if (e.key == .escape) {
                        left.requestClose();
                        right.requestClose();
                    }
                },
                .resize => |e| {
                    std.debug.print(
                        "resize: janela={d} {d}x{d}\n",
                        .{ e.window.index, e.width, e.height },
                    );
                },
                else => {},
            }
        }
    }
}
