// Zigway Core: tipos fundamentais da API publica.

const handles = @import("handles.zig");

pub const WindowId = handles.WindowId;
pub const DisplayId = handles.DisplayId;

/// Backend de plataforma. `.auto` resolve em tempo de execucao para o
/// padrao do alvo (ou para o `-Dplatform` do build, se diferente de auto).
pub const BackendKind = enum {
    auto,
    win32,
    x11,
    wayland,
    null_backend,
};

/// Backend efetivamente em uso apos resolucao (sem `.auto`, sem
/// nao-implementados).
pub const ActiveBackend = enum {
    win32,
    x11,
    null_backend,
};

/// Tecla logica (independente de layout para o conjunto mapeado).
/// Ordenada a partir de 0; usada como indice do conjunto de teclas.
pub const Key = enum(u16) {
    unknown = 0,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    n0,
    n1,
    n2,
    n3,
    n4,
    n5,
    n6,
    n7,
    n8,
    n9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    escape,
    tab,
    caps_lock,
    left_shift,
    right_shift,
    left_control,
    right_control,
    left_alt,
    right_alt,
    left_super,
    right_super,
    space,
    enter,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    num_lock,
    minus,
    equal,
    bracket_left,
    bracket_right,
    semicolon,
    apostrophe,
    grave,
    backslash,
    comma,
    period,
    slash,

    pub const count: usize = @typeInfo(Key).@"enum".field_names.len;
};

/// Botoes de ponteiro (roda vertical/horizontal chegam como Scroll).
pub const MouseButton = enum(u8) {
    left,
    right,
    middle,
    back,
    forward,

    pub const count: usize = @typeInfo(MouseButton).@"enum".field_names.len;
};

/// Cursores do sistema. Os backends mapeiam para formas nativas;
/// `.default` e a seta padrao do SO. `.not_allowed` usa a forma mais
/// proxima disponivel no X11 (XC_X_cursor).
pub const Cursor = enum(u8) {
    default,
    text,
    crosshair,
    hand,
    resize_horizontal,
    resize_vertical,
    resize_all,
    not_allowed,
    wait,

    pub const count: usize = @typeInfo(Cursor).@"enum".field_names.len;
};

/// Modificadores ativos no momento do evento.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    _reserved: u4 = 0,
};

/// Dimensoes da area de cliente em pixels.
pub const WindowSize = struct {
    width: u32,
    height: u32,
};

/// Posicao da janela em coordenadas de tela (quando o backend permite).
pub const WindowPosition = struct {
    x: i32,
    y: i32,
};

/// Monitor/display logico enumerado pelo backend.
///
/// `id` e um identificador opaco valido para o snapshot retornado por
/// `Platform.displays`; pode mudar se a configuracao de monitores mudar
/// (hotplug/reconfiguracao). As coordenadas sao relativas ao espaco de
/// tela do backend.
pub const DisplayInfo = struct {
    id: DisplayId,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    /// Monitor primario reportado pelo sistema (false se o servidor nao
    /// marcar nenhum).
    primary: bool,
};

const std = @import("std");

test "Key ordinals are dense from zero" {
    try std.testing.expectEqual(@as(u16, 0), @backingInt(Key.unknown));
    try std.testing.expect(Key.count > 64);
    // Ultima variante deve ter ordinal count - 1 (sem buracos).
    try std.testing.expectEqual(@as(u16, @intCast(Key.count - 1)), @backingInt(Key.slash));
}

test "Modifiers is one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Modifiers));
}

test "Cursor ordinals are dense from zero" {
    try std.testing.expectEqual(@as(u8, 0), @backingInt(Cursor.default));
    try std.testing.expectEqual(@as(u8, @intCast(Cursor.count - 1)), @backingInt(Cursor.wait));
}
