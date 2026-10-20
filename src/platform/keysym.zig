// Zigway: keysym X11/XKB -> tecla logica.
//
// Modulo compartilhado pelos backends que trabalham com keysyms: o
// X11 (keysym do servidor) e o Wayland (keysym do keymap XKB, que usa
// os mesmos valores de `X11/keysymdef.h`).
//
// Modulo-folha: importa apenas `core/types` (nao conhece `Platform`).

const std = @import("std");
const types = @import("../core/types.zig");

/// Keysyms usados no mapeamento (valores de `X11/keysymdef.h`).
pub const XK_BackSpace: u32 = 0xff08;
pub const XK_Tab: u32 = 0xff09;
pub const XK_Return: u32 = 0xff0d;
pub const XK_Escape: u32 = 0xff1b;
pub const XK_Home: u32 = 0xff50;
pub const XK_Left: u32 = 0xff51;
pub const XK_Up: u32 = 0xff52;
pub const XK_Right: u32 = 0xff53;
pub const XK_Down: u32 = 0xff54;
pub const XK_Page_Up: u32 = 0xff55;
pub const XK_Page_Down: u32 = 0xff56;
pub const XK_End: u32 = 0xff57;
pub const XK_Insert: u32 = 0xff63;
pub const XK_Delete: u32 = 0xffff;
pub const XK_Shift_L: u32 = 0xffe1;
pub const XK_Shift_R: u32 = 0xffe2;
pub const XK_Control_L: u32 = 0xffe3;
pub const XK_Control_R: u32 = 0xffe4;
pub const XK_Caps_Lock: u32 = 0xffe5;
pub const XK_Alt_L: u32 = 0xffe9;
pub const XK_Alt_R: u32 = 0xffea;
pub const XK_Super_L: u32 = 0xffeb;
pub const XK_Super_R: u32 = 0xffec;
pub const XK_Num_Lock: u32 = 0xff7f;
pub const XK_F1: u32 = 0xffbe;
pub const XK_KP_Enter: u32 = 0xff8d;
pub const XK_KP_Home: u32 = 0xff95;
pub const XK_KP_Left: u32 = 0xff96;
pub const XK_KP_Up: u32 = 0xff97;
pub const XK_KP_Right: u32 = 0xff98;
pub const XK_KP_Down: u32 = 0xff99;
pub const XK_KP_Prior: u32 = 0xff9a;
pub const XK_KP_Next: u32 = 0xff9b;
pub const XK_KP_End: u32 = 0xff9c;
pub const XK_KP_Insert: u32 = 0xff9e;
pub const XK_KP_Delete: u32 = 0xff9f;
pub const XK_KP_0: u32 = 0xffb0;

/// Converte um keysym X11 em codepoint Unicode.
///
/// Faixas do keysym (X11): 0x20-0x7E (ASCII), 0xA0-0xFF (Latin-1) e
/// 0x01000000-0x0110FFFF (Unicode direto, bit 24 marcado). Teclas sem
/// caractere (funcoes, modificadores) nao produzem texto.
pub fn toCodepoint(sym: u32) ?u32 {
    if (sym == 0) return null;
    if (sym >= 0x20 and sym <= 0x7E) return @intCast(sym);
    if (sym >= 0xA0 and sym <= 0xFF) return @intCast(sym);
    if (sym >= 0x0100_0000 and sym <= 0x0110_FFFF) {
        return @intCast(sym & 0x00FF_FFFF);
    }
    return null;
}

pub fn fromKeysym(sym: u32) types.Key {
    // Letras (minusculas e maiusculas -> mesma tecla logica).
    if ((sym >= 0x61 and sym <= 0x7a) or (sym >= 0x41 and sym <= 0x5a)) {
        const lower = sym | 0x20;
        return switch (lower) {
            0x61 => .a,
            0x62 => .b,
            0x63 => .c,
            0x64 => .d,
            0x65 => .e,
            0x66 => .f,
            0x67 => .g,
            0x68 => .h,
            0x69 => .i,
            0x6a => .j,
            0x6b => .k,
            0x6c => .l,
            0x6d => .m,
            0x6e => .n,
            0x6f => .o,
            0x70 => .p,
            0x71 => .q,
            0x72 => .r,
            0x73 => .s,
            0x74 => .t,
            0x75 => .u,
            0x76 => .v,
            0x77 => .w,
            0x78 => .x,
            0x79 => .y,
            0x7a => .z,
            else => .unknown,
        };
    }
    if (sym >= 0x30 and sym <= 0x39) {
        return switch (sym) {
            0x30 => .n0,
            0x31 => .n1,
            0x32 => .n2,
            0x33 => .n3,
            0x34 => .n4,
            0x35 => .n5,
            0x36 => .n6,
            0x37 => .n7,
            0x38 => .n8,
            0x39 => .n9,
            else => .unknown,
        };
    }
    if (sym >= XK_F1 and sym < XK_F1 + 12) {
        return switch (sym - XK_F1) {
            0 => .f1,
            1 => .f2,
            2 => .f3,
            3 => .f4,
            4 => .f5,
            5 => .f6,
            6 => .f7,
            7 => .f8,
            8 => .f9,
            9 => .f10,
            10 => .f11,
            11 => .f12,
            else => .unknown,
        };
    }
    // Teclado numerico: mesmas teclas logicas do Win32. Com NumLock
    // ligado, XK_KP_0..9 -> n0..n9; desligado, o servidor entrega as
    // chaves de navegacao XK_KP_Home etc. `Key` nao distingue numpad da
    // linha superior (nem o Win32 distingue). Operadores (KP_Add,
    // KP_Multiply, ...) nao tem variante em `Key` e seguem `.unknown`,
    // como no Win32 (VK_ADD/VK_MULTIPLY tambem nao mapeados).
    if (sym >= XK_KP_0 and sym <= XK_KP_0 + 9) {
        return switch (sym - XK_KP_0) {
            0 => .n0,
            1 => .n1,
            2 => .n2,
            3 => .n3,
            4 => .n4,
            5 => .n5,
            6 => .n6,
            7 => .n7,
            8 => .n8,
            9 => .n9,
            else => .unknown,
        };
    }
    return switch (sym) {
        XK_Escape => .escape,
        XK_Tab => .tab,
        XK_Return => .enter,
        XK_BackSpace => .backspace,
        XK_Delete => .delete,
        XK_Insert => .insert,
        XK_Home => .home,
        XK_End => .end,
        XK_Page_Up => .page_up,
        XK_Page_Down => .page_down,
        XK_Left => .left,
        XK_Up => .up,
        XK_Right => .right,
        XK_Down => .down,
        XK_Shift_L => .left_shift,
        XK_Shift_R => .right_shift,
        XK_Control_L => .left_control,
        XK_Control_R => .right_control,
        XK_Caps_Lock => .caps_lock,
        XK_Num_Lock => .num_lock,
        XK_KP_Enter => .enter,
        XK_KP_Home => .home,
        XK_KP_Left => .left,
        XK_KP_Up => .up,
        XK_KP_Right => .right,
        XK_KP_Down => .down,
        XK_KP_Prior => .page_up,
        XK_KP_Next => .page_down,
        XK_KP_End => .end,
        XK_KP_Insert => .insert,
        XK_KP_Delete => .delete,
        XK_Alt_L => .left_alt,
        XK_Alt_R => .right_alt,
        XK_Super_L => .left_super,
        XK_Super_R => .right_super,
        0x20 => .space,
        0x2d => .minus,
        0x3d => .equal,
        0x5b => .bracket_left,
        0x5d => .bracket_right,
        0x3b => .semicolon,
        0x27 => .apostrophe,
        0x60 => .grave,
        0x5c => .backslash,
        0x2c => .comma,
        0x2e => .period,
        0x2f => .slash,
        else => .unknown,
    };
}

test "keysym mapping covers basics" {
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x61));
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x41));
    try std.testing.expectEqual(types.Key.n0, fromKeysym(0x30));
    try std.testing.expectEqual(types.Key.f1, fromKeysym(XK_F1));
    try std.testing.expectEqual(types.Key.f12, fromKeysym(XK_F1 + 11));
    try std.testing.expectEqual(types.Key.space, fromKeysym(0x20));
    try std.testing.expectEqual(types.Key.unknown, fromKeysym(0));
}

test "keysym to codepoint covers ascii, latin1 and unicode" {
    try std.testing.expectEqual(@as(?u32, null), toCodepoint(0));
    try std.testing.expectEqual(@as(?u32, null), toCodepoint(0xFF0B)); // XK_F1
    try std.testing.expectEqual(@as(?u32, null), toCodepoint(0x0100_0000 - 1));
    try std.testing.expectEqual(@as(?u32, 0x20), toCodepoint(0x20)); // espaco
    try std.testing.expectEqual(@as(?u32, 0x61), toCodepoint(0x61)); // 'a'
    try std.testing.expectEqual(@as(?u32, 0x7E), toCodepoint(0x7E)); // '~'
    try std.testing.expectEqual(@as(?u32, 0xE4), toCodepoint(0xE4)); // a-dieresis
    try std.testing.expectEqual(@as(?u32, 0x10FFFF), toCodepoint(0x0110_FFFF));
}
