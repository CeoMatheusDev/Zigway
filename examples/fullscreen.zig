// fullscreen: alterna fullscreen com F11 e fecha com Esc.

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

    var window = try platform.createWindow(.{
        .width = 640,
        .height = 480,
        .title = "Zigway — fullscreen",
    });
    defer window.deinit();

    std.debug.print("zigway: F11 alterna fullscreen; Esc fecha.\n", .{});

    while (!window.shouldClose()) {
        platform.pollEvents();
        while (platform.nextEvent()) |event| {
            switch (event) {
                .close => |e| {
                    if (e.window.eql(window.windowId())) window.requestClose();
                },
                .key_down => |e| {
                    switch (e.key) {
                        .escape => window.requestClose(),
                        .f11 => {
                            const next = !window.isFullscreen();
                            window.setFullscreen(next) catch |err| {
                                std.debug.print("zigway: fullscreen falhou: {t}\n", .{err});
                            };
                        },
                        else => {},
                    }
                },
                .fullscreen => |e| {
                    if (e.window.eql(window.windowId())) {
                        std.debug.print("zigway: fullscreen={}\n", .{e.fullscreen});
                    }
                },
                else => {},
            }
        }
    }
}
