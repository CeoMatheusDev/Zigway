// Zigway build system (Zig 0.17.0).
//
// Backends selecionaveis em tempo de compilacao:
//
//   zig build                       (padrao: auto)
//   zig build -Dplatform=auto
//   zig build -Dplatform=null_backend  (headless; util para CI)
//   zig build -Dplatform=x11        (somente Linux)
//   zig build -Dplatform=win32      (somente Windows)
//   zig build -Dplatform=wayland    (rejeitado: ainda nao implementado)
//
// A opcao -Dplatform define o backend padrao usado quando
// Platform.Options.backend == .auto e valida a combinacao
// backend/alvo ja no build, com erro claro em caso de
// incompatibilidade.

const std = @import("std");

const PlatformChoice = enum {
    auto,
    win32,
    x11,
    wayland,
    null_backend,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os_tag = target.result.os.tag;

    const choice = b.option(
        PlatformChoice,
        "platform",
        "Backend padrao quando Platform.Options.backend == .auto (default: auto)",
    ) orelse .auto;

    switch (choice) {
        .win32 => {
            if (os_tag != .windows) {
                std.debug.panic(
                    "zigway: -Dplatform=win32 exige alvo Windows (alvo atual: {s})",
                    .{@tagName(os_tag)},
                );
            }
        },
        .x11 => {
            if (os_tag != .linux) {
                std.debug.panic(
                    "zigway: -Dplatform=x11 exige alvo Linux (alvo atual: {s})",
                    .{@tagName(os_tag)},
                );
            }
        },
        .wayland => {
            std.debug.panic(
                "zigway: backend Wayland ainda nao implementado (ver src/platform/wayland/README.md)",
                .{},
            );
        },
        .auto, .null_backend => {},
    }

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "default_platform", @tagName(choice));

    const mod = b.addModule("zigway", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_opts);
    linkNative(mod, os_tag);

    const lib = b.addLibrary(.{
        .name = "zigway",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addOptions("build_options", build_opts);
    linkNative(lib.root_module, os_tag);
    b.installArtifact(lib);

    // Testes unitarios (sem display; backend null + logica central).
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    // O teste de sincronia de versao le build.zig.zon em compilacao:
    // declara-lo como entrada invalida o cache quando so o zon muda.
    run_mod_tests.addFileInput(b.path("build.zig.zon"));
    const test_step = b.step("test", "Executa os testes unitarios (headless)");
    test_step.dependOn(&run_mod_tests.step);

    // Teste live X11 (abre display real; pula graciosamente sem display).
    const live_mod = b.createModule(.{
        .root_source_file = b.path("tests/live_x11.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigway", .module = mod }},
    });
    const live_test = b.addTest(.{ .root_module = live_mod });
    const run_live = b.addRunArtifact(live_test);
    const live_step = b.step("test-x11", "Executa o teste live X11 (requer display)");
    live_step.dependOn(&run_live.step);

    // Exemplos.
    const examples_step = b.step("examples", "Compila os exemplos");
    const example_names = [_][]const u8{
        "hello_window",
        "multiple_windows",
        "keyboard_input",
        "displays",
    };
    inline for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigway", .module = mod }},
            }),
        });
        linkNative(exe.root_module, os_tag);
        b.installArtifact(exe);
        examples_step.dependOn(b.getInstallStep());
    }
}

fn linkNative(mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    switch (os_tag) {
        .linux => {
            mod.linkSystemLibrary("c", .{});
            mod.linkSystemLibrary("X11", .{});
        },
        .windows => {
            mod.linkSystemLibrary("c", .{});
            mod.linkSystemLibrary("kernel32", .{});
            mod.linkSystemLibrary("user32", .{});
            mod.linkSystemLibrary("gdi32", .{});
        },
        else => {
            mod.linkSystemLibrary("c", .{});
        },
    }
}
