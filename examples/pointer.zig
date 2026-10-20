// pointer: movimento relativo, pointer lock e confinamento.
//
// Demonstra a diferenca entre as tres operacoes de ponteiro:
//   - captura (`capturePointer`): o ponteiro fica preso a janela, mas
//     ainda entrega posicoes absolutas;
//   - lock (`setPointerConstraint(.lock, null)`): o ponteiro nao se
//     move na tela; a aplicacao recebe deltas relativos;
//   - confinamento (`setPointerConstraint(.confine, regiao)`): o
//     ponteiro fica dentro de uma regiao da janela.
//
// O evento `pointer_constraint` traz o estado efetivo (no Wayland, o
// compositor confirma o lock; em X11/Win32 a restricao vale na hora).

const std = @import("std");
const zigway = @import("zigway");

const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var platform = zigway.Platform.init(allocator, .{}) catch |err| {
        std.debug.print("zigway: Platform.init falhou: {t}\n", .{err});
        return err;
    };
    defer platform.deinit();

    const caps = platform.capabilities();
    std.debug.print("backend {t}: relativo={} lock={} confinamento={}\n", .{
        platform.backendKind(),
        caps.pointer_relative,
        caps.pointer_lock,
        caps.pointer_confinement,
    });

    var window = try platform.createWindow(.{
        .width = 640,
        .height = 480,
        .title = "zigway-pointer",
    });
    defer window.deinit();

    // Lock: o ponteiro fica no lugar e os eventos viram deltas.
    if (caps.pointer_lock) {
        window.setPointerConstraint(.lock, null) catch |err| {
            std.debug.print("lock nao disponivel: {t}\n", .{err});
        };
    }

    var frames: u32 = 0;
    while (frames < 600) : (frames += 1) {
        platform.pollEvents();
        while (platform.nextEvent()) |event| {
            switch (event) {
                .pointer_relative => |rel| {
                    std.debug.print("relativo: dx={d:.2} dy={d:.2} (raw {d:.2}/{d:.2})\n", .{
                        rel.dx,
                        rel.dy,
                        rel.dx_unaccelerated orelse 0.0,
                        rel.dy_unaccelerated orelse 0.0,
                    });
                },
                .pointer_constraint => |c| {
                    std.debug.print("restricao agora: {t}\n", .{c.constraint});
                },
                .pointer_move => |m| {
                    std.debug.print("absoluto: ({d},{d})\n", .{ m.x, m.y });
                },
                .close => {
                    std.debug.print("janela fechada\n", .{});
                    return;
                },
                else => {},
            }
        }
        var ts: Timespec = .{ .sec = 0, .nsec = 16 * std.time.ns_per_ms };
        _ = nanosleep(&ts, null);
    }

    // Libera a restricao antes de sair (evita deixar o ponteiro preso).
    window.setPointerConstraint(.none, null) catch {};
}
