// Zigway Core: tipos fundamentais da API publica.

const handles = @import("handles.zig");

pub const WindowId = handles.WindowId;
pub const DisplayId = handles.DisplayId;
pub const DisplayModeId = handles.DisplayModeId;

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
    wayland,
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

/// Limites de tamanho da area de cliente em pixels.
///
/// `min_* == 0` significa sem minimo explicito. `max_* == 0` significa
/// sem maximo explicito para aquele eixo. Quando ambos os maximos sao
/// zero, o backend remove a restricao de tamanho maximo.
pub const WindowSizeLimits = struct {
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
};

/// Posicao da origem da area de cliente em coordenadas de tela do
/// backend. Para X11/Win32 e consultada no recurso nativo quando possivel.
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

/// Modo de video oferecido por um display.
///
/// `id` e opaco e deve ser usado em `Platform.setDisplayMode`; e valido
/// apenas enquanto a configuracao de display nao mudar. `refresh_mhz` e a
/// taxa vertical aproximada em milihertz (0 quando desconhecida).
/// `current`/`preferred` sao dicas do snapshot, nao garantias.
pub const DisplayMode = struct {
    id: DisplayModeId,
    width: u32,
    height: u32,
    refresh_mhz: u32 = 0,
    current: bool = false,
    preferred: bool = false,
};

/// Capacidades do backend, para que a aplicacao adapte o
/// comportamento sem identificar manualmente o backend.
///
/// Tudo que e `false` deve ser tratado como "nao disponivel": a API
/// correspondente retorna `error.NotImplemented`/`Unsupported` ou um
/// resultado vazio (ver a documentacao de cada funcao).
pub const Capabilities = struct {
    /// `setPosition` posiciona a janela em coordenadas de tela.
    absolute_positioning: bool = false,
    /// A aplicacao escolhe o tamanho da janela (`setSize`).
    resize_request: bool = false,
    /// A aplicacao pede foco (`focus`).
    focus_request: bool = false,
    /// Area de transferencia (texto) disponivel.
    clipboard: bool = false,
    /// Entrada de texto Unicode/IME (composicao, dead keys).
    text_input_ime: bool = false,
    /// O backend aceita texto circundante (`setSurroundingText`).
    surrounding_text: bool = false,
    /// Cursor do sistema por janela.
    system_cursor: bool = false,
    /// Captura exclusiva do ponteiro.
    pointer_capture: bool = false,
    /// Movimento relativo do ponteiro (delta, nao posicao).
    pointer_relative: bool = false,
    /// Bloqueio do ponteiro a uma janela (pointer lock).
    pointer_lock: bool = false,
    /// Confinamento do ponteiro a uma regiao da janela.
    pointer_confinement: bool = false,
    /// Escala fracionaria por janela (Wayland).
    fractional_scale: bool = false,
    /// DPI por monitor (Win32); no X11 a escala e aproximada e global.
    dpi_per_monitor: bool = false,
    /// Modos de video (resolucao) por display.
    video_modes: bool = false,
    /// O backend modela um "seat" (dispositivos de entrada).
    seat: bool = false,
};

/// Restricao aplicada ao ponteiro de uma janela.
///
/// - `none`: sem restricao (comportamento normal).
/// - `lock`: o ponteiro fica preso a janela (movimento relativo).
/// - `confine`: o ponteiro fica dentro de uma regiao da janela.
pub const PointerConstraint = enum {
    none,
    lock,
    confine,
};

/// Regiao de confinamento do ponteiro, em coordenadas **logicas**
/// relativas a area de cliente da janela (a mesma unidade de
/// `Window.size()`; a escala e aplicada pelo backend).
pub const ConstraintRegion = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// Escala de exibicao de uma janela ou display.
///
/// Razao entre pixels fisicos e unidades logicas: `1/1` = 100%,
/// `3/2` = 150%. O Wayland pode ser fracionaria (o compositor anuncia
/// `wp_fractional_scale_v1`); X11 e Win32 usam valores inteiros
/// (por monitor no Win32, aproximado no X11).
///
/// Unidades: o *tamanho logico* e expresso em unidades de superficie
/// (o que o compositor informa no `configure`); o *tamanho fisico* (o
/// buffer) e o tamanho logico multiplicado pela escala.
pub const Scale = struct {
    numerator: u32 = 1,
    denominator: u32 = 1,

    pub const identity: Scale = .{};

    /// Escala como fracao de ponto flutuante (1.5 = 150%).
    pub fn toFloat(self: Scale) f64 {
        if (self.denominator == 0) return 1.0;
        return @as(f64, @floatFromInt(self.numerator)) /
            @as(f64, @floatFromInt(self.denominator));
    }

    /// true quando a escala nao e um multiplo inteiro de 1/1.
    pub fn isFractional(self: Scale) bool {
        if (self.denominator == 0) return false;
        return self.numerator % self.denominator != 0;
    }

    pub fn eql(self: Scale, other: Scale) bool {
        return self.numerator == other.numerator and self.denominator == other.denominator;
    }

    /// Converte um tamanho logico no tamanho fisico do buffer
    /// (arredondado para cima, para nao cortar conteudo).
    pub fn applyToSize(self: Scale, size: WindowSize) WindowSize {
        const n = @as(u64, self.numerator);
        const d = @as(u64, if (self.denominator == 0) 1 else self.denominator);
        return .{
            .width = @intCast((@as(u64, size.width) * n + d - 1) / d),
            .height = @intCast((@as(u64, size.height) * n + d - 1) / d),
        };
    }
};

/// Capacidades de entrada do "seat" (dispositivos de entrada) do
/// compositor. `null` quando o backend nao modela um seat.
pub const SeatCapabilities = struct {
    pointer: bool = false,
    keyboard: bool = false,
    touch: bool = false,
};

const std = @import("std");

test "scale arithmetic and size conversion" {
    const one = Scale.identity;
    try std.testing.expectEqual(@as(f64, 1.0), one.toFloat());
    try std.testing.expect(!one.isFractional());

    const half = Scale{ .numerator = 3, .denominator = 2 };
    try std.testing.expectEqual(@as(f64, 1.5), half.toFloat());
    try std.testing.expect(half.isFractional());

    const integer = Scale{ .numerator = 2, .denominator = 1 };
    try std.testing.expect(!integer.isFractional());

    // 800x600 logico a 150% => 1200x900 de buffer.
    const sized = half.applyToSize(.{ .width = 800, .height = 600 });
    try std.testing.expectEqual(@as(u32, 1200), sized.width);
    try std.testing.expectEqual(@as(u32, 900), sized.height);

    // Arredonda para cima (nao corta o conteudo).
    const odd = half.applyToSize(.{ .width = 101, .height = 101 });
    try std.testing.expectEqual(@as(u32, 152), odd.width);
    try std.testing.expectEqual(@as(u32, 152), odd.height);

    // Divisor zero nao divide por zero.
    const broken = Scale{ .numerator = 1, .denominator = 0 };
    try std.testing.expectEqual(@as(f64, 1.0), broken.toFloat());
}

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
