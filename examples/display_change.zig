// display_change: reconsulta os monitores quando o SO avisa que o
// display mudou (hotplug, resolucao, RandR/WM_DISPLAYCHANGE).

const std = @import("std");
const zigway = @import("zigway");

fn printDisplays(platform: *zigway.Platform, allocator: std.mem.Allocator) !void {
    const displays = try platform.displays(allocator);
    defer allocator.free(displays);

    std.debug.print("zigway: {d} display(s)\n", .{displays.len});
    for (displays, 0..) |info, i| {
        std.debug.print(
            "  [{d}] id={d} pos=({d},{d}) size={d}x{d} primary={}\n",
            .{ i, info.id.raw, info.x, info.y, info.width, info.height, info.primary },
        );
    }
}

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
        .width = 520,
        .height = 360,
        .title = "Zigway — display_change",
    });
    defer window.deinit();

    try printDisplays(&platform, allocator);
    std.debug.print("zigway: aguardando mudancas (Esc fecha)...\n", .{});

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
                .display_change => {
                    std.debug.print("zigway: display mudou; reconsultando...\n", .{});
                    try printDisplays(&platform, allocator);
                },
                else => {},
            }
        }
    }
}
