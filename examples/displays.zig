// displays: lista monitores/display outputs do backend ativo.

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

    const displays = try platform.displays(allocator);
    defer allocator.free(displays);

    std.debug.print("zigway: backend {t}, {d} display(s)\n", .{
        platform.backendKind(),
        displays.len,
    });
    for (displays, 0..) |info, i| {
        std.debug.print(
            "  [{d}] id={d} pos=({d},{d}) size={d}x{d} primary={}\n",
            .{ i, info.id.raw, info.x, info.y, info.width, info.height, info.primary },
        );
    }
}
