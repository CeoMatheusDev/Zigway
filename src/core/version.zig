// Zigway Core: versionamento (SemVer 2.0.0).
//
// A versao canonica do pacote vive em build.zig.zon; os numeros abaixo
// devem acompanha-la e sao verificados por teste.

pub const major: u32 = 0;
pub const minor: u32 = 1;
pub const patch: u32 = 0;
pub const prerelease: []const u8 = "alpha.1";

pub const string: []const u8 = "0.1.0-alpha.1";

/// Versao do Zig exigida para compilar esta release.
pub const required_zig: []const u8 = "0.17.0";

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: []const u8,

    pub fn current() Version {
        return .{
            .major = major,
            .minor = minor,
            .patch = patch,
            .prerelease = prerelease,
        };
    }
};

test "version numbers match version string" {
    const std = @import("std");
    var buf: [64]u8 = undefined;
    const rendered = if (prerelease.len == 0)
        try std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ major, minor, patch })
    else
        try std.fmt.bufPrint(&buf, "{d}.{d}.{d}-{s}", .{ major, minor, patch, prerelease });
    try std.testing.expectEqualStrings(string, rendered);
}
