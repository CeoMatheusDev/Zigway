// bench_loop: metricas do loop de eventos (latencia de wakeup e custo de
// poll).
//
// Metodologia: a latencia de `wakeup` e medida com uma thread auxiliar
// que sinaliza o loop; o tempo inclui o despertar da thread, entao e um
// limite superior do custo interno (nao mede a latencia do compositor).
// O custo de `poll` e medido com a fila vazia.
//
// Executar com: zig build examples && ./zig-out/bin/bench_loop

const std = @import("std");
const zigway = @import("zigway");

const Timespec = extern struct {
    sec: isize,
    nsec: isize,
};

extern "c" fn clock_gettime(clk_id: c_int, ts: *Timespec) c_int;

/// Relogio monotonico em nanossegundos.
fn now() i128 {
    var ts: Timespec = undefined;
    _ = clock_gettime(0, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var plat = try zigway.Platform.init(allocator, .{});
    defer plat.deinit();

    // 1) Latencia do wakeup (thread auxiliar sinaliza o loop).
    const N = 200;
    var samples: [N]u64 = undefined;
    for (0..N) |i| {
        const Waker = struct {
            plat: *zigway.Platform,
            fn run(self: *@This()) void {
                self.plat.wakeup();
            }
        };
        var waker = Waker{ .plat = &plat };
        const thread = try std.Thread.spawn(.{}, Waker.run, .{&waker});
        const t0 = now();
        _ = plat.waitEvents(1000);
        const elapsed: u64 = @intCast(now() - t0);
        thread.join();
        samples[i] = elapsed;
    }
    // (amostras ordenadas: a primeira e o minimo, a ultima o maximo)
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const med = samples[samples.len / 2];
    const min_ns = samples[0];
    const max_ns = samples[samples.len - 1];
    std.debug.print("wakeup: mediana {d}us (min {d}us, max {d}us, n={d})\n", .{
        med / 1000,
        min_ns / 1000,
        max_ns / 1000,
        N,
    });

    // 2) Custo de `pollEvents` com a fila vazia (sem syscall de espera).
    const P = 10_000;
    const t_poll = now();
    for (0..P) |_| plat.pollEvents();
    const poll_ns = now() - t_poll;
    std.debug.print("poll: {d}ns por chamada (n={d})\n", .{ @divTrunc(poll_ns, P), P });

    // 3) Custo de `waitEvents` com timeout zero (caminho sem espera).
    const t_wait = now();
    for (0..P) |_| _ = plat.waitEvents(0);
    const wait_ns = now() - t_wait;
    std.debug.print("waitEvents(0): {d}ns por chamada (n={d})\n", .{ @divTrunc(wait_ns, P), P });
}
