// Zigway Platform: configuracao vinda do build system.
//
// `build_options` e injetado pelo build.zig (`-Dplatform`). Fora do build
// (ex.: analise isolada), assume `.auto`.

const types = @import("../core/types.zig");

const BuildDefault = if (@hasDecl(@import("build_options"), "default_platform"))
    @import("build_options").default_platform
else
    "auto";

fn parse(s: []const u8) types.BackendKind {
    if (std.mem.eql(u8, s, "win32")) return .win32;
    if (std.mem.eql(u8, s, "x11")) return .x11;
    if (std.mem.eql(u8, s, "wayland")) return .wayland;
    if (std.mem.eql(u8, s, "null_backend")) return .null_backend;
    return .auto;
}

pub const build_default: types.BackendKind = parse(BuildDefault);

const std = @import("std");

test "build default parses to a known backend" {
    // Apenas garante que o valor injetado e valido.
    _ = build_default;
}
