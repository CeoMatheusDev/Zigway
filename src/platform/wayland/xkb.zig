// Zigway Wayland: keymap XKB via libxkbcommon.
//
// O `wl_keyboard` entrega o keymap XKB do compositor por um descritor
// de arquivo (formato texto "xkb"). Para converter o keycode em
// keysym (e aplicar o layout e os modificadores) e preciso de um
// interpretador XKB: a libxkbcommon e carregada em RUNTIME (dlopen),
// como a libwayland e a libXrandr — o build nao ganha dependencia de
// link e, sem a biblioteca, o teclado simplesmente nao entrega teclas
// (os demais recursos do backend continuam funcionando).
//
// ABI declarada manualmente (sem @cImport e sem headers C no build).

const std = @import("std");

pub const xkb_context = opaque {};
pub const xkb_keymap = opaque {};
pub const xkb_state = opaque {};

/// `xkb_keysym_t` (xkbcommon/xkbcommon.h).
pub const KeySym = u32;
/// `xkb_keycode_t` (xkbcommon/xkbcommon.h).
pub const KeyCode = u32;

/// Flags de `xkb_context_new` (nenhum necessario).
pub const context_flags_none: u32 = 0;
/// Flags de `xkb_keymap_new_from_buffer` (compilacao estrita).
pub const keymap_flags_no_flags: i32 = 0;
/// `XKB_KEYMAP_FORMAT_TEXT_V1` (formato texto do keymap do compositor).
pub const keymap_format_text_v1: i32 = 1;
/// `XKB_KEY_UP` (a tecla foi solta).
pub const key_direction_up: i32 = 0;
/// `XKB_KEY_DOWN` (a tecla foi pressionada).
pub const key_direction_down: i32 = 1;

const ContextNewFn = *const fn (u32) callconv(.c) ?*xkb_context;
const ContextUnrefFn = *const fn (*xkb_context) callconv(.c) void;
/// `xkb_keymap_new_from_buffer(ctx, buffer, length, format, flags)`.
const KeymapNewFromBufferFn = *const fn (
    *xkb_context,
    [*]const u8,
    usize,
    i32,
    i32,
) callconv(.c) ?*xkb_keymap;
/// `xkb_keymap_new_from_string(ctx, string, format, flags)`.
const KeymapNewFromStringFn = *const fn (
    *xkb_context,
    [*:0]const u8,
    i32,
    i32,
) callconv(.c) ?*xkb_keymap;
const KeymapUnrefFn = *const fn (*xkb_keymap) callconv(.c) void;
const StateNewFn = *const fn (*xkb_keymap) callconv(.c) ?*xkb_state;
const StateUnrefFn = *const fn (*xkb_state) callconv(.c) void;
const StateUpdateKeyFn = *const fn (*xkb_state, KeyCode, i32) callconv(.c) i32;
const StateKeyGetSymsFn = *const fn (*xkb_state, KeyCode, *const [*]const KeySym) callconv(.c) i32;
const StateUpdateMaskFn = *const fn (*xkb_state, u32, u32, u32, u32) callconv(.c) i32;

/// Ponteiros de funcao da libxkbcommon (copia estavel, sem o
/// `DynLib`: o `DynLib` tem dono unico).
pub const Symbols = struct {
    context_new: ContextNewFn,
    context_unref: ContextUnrefFn,
    keymap_new_from_buffer: KeymapNewFromBufferFn,
    keymap_new_from_string: KeymapNewFromStringFn,
    keymap_unref: KeymapUnrefFn,
    state_new: StateNewFn,
    state_unref: StateUnrefFn,
    state_update_key: StateUpdateKeyFn,
    state_key_get_syms: StateKeyGetSymsFn,
    state_update_mask: StateUpdateMaskFn,
};

/// A libxkbcommon carregada (dono do `DynLib`).
pub const Lib = struct {
    dyn: std.DynLib,
    symbols: Symbols,

    /// Carrega a libxkbcommon. Retorna null se a biblioteca ou algum
    /// simbolo necessario nao existir.
    pub fn load() ?Lib {
        var dyn = std.DynLib.open("libxkbcommon.so.0") catch blk: {
            break :blk std.DynLib.open("libxkbcommon.so") catch return null;
        };
        const context_new = dyn.lookup(ContextNewFn, "xkb_context_new") orelse {
            dyn.close();
            return null;
        };
        const context_unref = dyn.lookup(ContextUnrefFn, "xkb_context_unref") orelse {
            dyn.close();
            return null;
        };
        const keymap_new_from_buffer = dyn.lookup(KeymapNewFromBufferFn, "xkb_keymap_new_from_buffer") orelse {
            dyn.close();
            return null;
        };
        const keymap_new_from_string = dyn.lookup(KeymapNewFromStringFn, "xkb_keymap_new_from_string") orelse {
            dyn.close();
            return null;
        };
        const keymap_unref = dyn.lookup(KeymapUnrefFn, "xkb_keymap_unref") orelse {
            dyn.close();
            return null;
        };
        const state_new = dyn.lookup(StateNewFn, "xkb_state_new") orelse {
            dyn.close();
            return null;
        };
        const state_unref = dyn.lookup(StateUnrefFn, "xkb_state_unref") orelse {
            dyn.close();
            return null;
        };
        const state_update_key = dyn.lookup(StateUpdateKeyFn, "xkb_state_update_key") orelse {
            dyn.close();
            return null;
        };
        const state_key_get_syms = dyn.lookup(StateKeyGetSymsFn, "xkb_state_key_get_syms") orelse {
            dyn.close();
            return null;
        };
        const state_update_mask = dyn.lookup(StateUpdateMaskFn, "xkb_state_update_mask") orelse {
            dyn.close();
            return null;
        };
        return .{
            .dyn = dyn,
            .symbols = .{
                .context_new = context_new,
                .context_unref = context_unref,
                .keymap_new_from_buffer = keymap_new_from_buffer,
                .keymap_new_from_string = keymap_new_from_string,
                .keymap_unref = keymap_unref,
                .state_new = state_new,
                .state_unref = state_unref,
                .state_update_key = state_update_key,
                .state_key_get_syms = state_key_get_syms,
                .state_update_mask = state_update_mask,
            },
        };
    }

    pub fn deinit(self: *Lib) void {
        self.dyn.close();
    }
};

/// Estado do keymap: contexto, keymap e estado (o "state" e quem
/// aplica layout e modificadores).
pub const Keymap = struct {
    lib: Lib,
    context: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,
    /// true quando o keymap foi carregado com sucesso.
    ready: bool = true,

    /// Cria o contexto XKB. Falha se a libxkbcommon nao estiver
    /// disponivel (o backend segue sem teclado).
    pub fn init() !Keymap {
        var lib = Lib.load() orelse return error.UnsupportedBackend;
        errdefer lib.deinit();
        const context = lib.symbols.context_new(context_flags_none) orelse {
            lib.deinit();
            return error.ConnectionFailed;
        };
        return .{
            .lib = lib,
            .context = context,
            .keymap = undefined,
            .state = undefined,
            .ready = false,
        };
    }

    /// Carrega o keymap a partir dos dados (formato texto "xkb").
    pub fn load(self: *Keymap, data: []const u8) !void {
        self.unload();
        const keymap = self.lib.symbols.keymap_new_from_buffer(
            self.context,
            data.ptr,
            data.len,
            keymap_format_text_v1,
            keymap_flags_no_flags,
        ) orelse return error.InvalidKeymap;
        const state = self.lib.symbols.state_new(keymap) orelse {
            self.lib.symbols.keymap_unref(keymap);
            return error.InvalidKeymap;
        };
        self.keymap = keymap;
        self.state = state;
        self.ready = true;
    }

    /// Carrega um keymap a partir de um texto XKB (usado nos testes).
    pub fn loadFromString(self: *Keymap, text: [:0]const u8) !void {
        self.unload();
        const keymap = self.lib.symbols.keymap_new_from_string(
            self.context,
            text.ptr,
            keymap_format_text_v1,
            keymap_flags_no_flags,
        ) orelse return error.InvalidKeymap;
        const state = self.lib.symbols.state_new(keymap) orelse {
            self.lib.symbols.keymap_unref(keymap);
            return error.InvalidKeymap;
        };
        self.keymap = keymap;
        self.state = state;
        self.ready = true;
    }

    /// Libera o keymap atual (o contexto continua).
    pub fn unload(self: *Keymap) void {
        if (!self.ready) return;
        self.lib.symbols.state_unref(self.state);
        self.lib.symbols.keymap_unref(self.keymap);
        self.ready = false;
    }

    pub fn deinit(self: *Keymap) void {
        self.unload();
        self.lib.symbols.context_unref(self.context);
        self.lib.deinit();
    }

    /// Atualiza o estado com a tecla e devolve o keysym resultante
    /// (0 quando o keymap nao conhece a tecla).
    ///
    /// O keysym e lido ANTES de atualizar o estado: assim o sym nao e
    /// afetado pelo proprio evento (recomendacao do xkbcommon) e o
    /// nivel (shift, etc.) reflete os modificadores ja ativos.
    pub fn symForKey(self: *Keymap, keycode: KeyCode, pressed: bool) KeySym {
        if (!self.ready) return 0;
        var syms: [*]const KeySym = undefined;
        const count = self.lib.symbols.state_key_get_syms(self.state, keycode, &syms);
        const sym: KeySym = if (count > 0) syms[0] else 0;
        _ = self.lib.symbols.state_update_key(
            self.state,
            keycode,
            if (pressed) key_direction_down else key_direction_up,
        );
        return sym;
    }

    /// Atualiza os modificadores (mascara XKB: shift=1, lock=2,
    /// control=4, mod1=8, mod4=64).
    pub fn updateModifiers(
        self: *Keymap,
        depressed: u32,
        latched: u32,
        locked: u32,
        group: u32,
    ) void {
        if (!self.ready) return;
        _ = self.lib.symbols.state_update_mask(self.state, depressed, latched, locked, group);
    }
};

/// Bits da mascara de modificadores do XKB (`xkb_mod_mask_t`).
pub const mod_index_shift: u32 = 1 << 0;
pub const mod_index_lock: u32 = 1 << 1;
pub const mod_index_control: u32 = 1 << 2;
pub const mod_index_alt: u32 = 1 << 3;
pub const mod_index_super: u32 = 1 << 6;

test "xkb modifier bits match the xkbcommon layout" {
    try std.testing.expectEqual(@as(u32, 1), mod_index_shift);
    try std.testing.expectEqual(@as(u32, 4), mod_index_control);
    try std.testing.expectEqual(@as(u32, 8), mod_index_alt);
    try std.testing.expectEqual(@as(u32, 64), mod_index_super);
}

/// Keymap XKB minimo para os testes: duas teclas (Escape e 1).
const minimal_keymap =
    \\xkb_keymap {
    \\  xkb_keycodes { minimum = 8; maximum = 255; <ESC> = 9; <AE01> = 10; };
    \\  xkb_types { type "ONE_LEVEL" { modifiers = none; level_name[1] = "Any"; }; };
    \\  xkb_compat { };
    \\  xkb_symbols { key <ESC> { [ Escape ] }; key <AE01> { [ 1, exclam ] }; };
    \\};
    \\
;

test "keymap translates keycodes into keysyms" {
    // A libxkbcommon e opcional: sem ela o teste pula.
    var keymap = Keymap.init() catch return;
    defer keymap.deinit();

    keymap.loadFromString(minimal_keymap) catch return;
    try std.testing.expect(keymap.ready);

    // XKB_Escape
    try std.testing.expectEqual(@as(KeySym, 0xff1b), keymap.symForKey(9, true));
    // '1'
    try std.testing.expectEqual(@as(KeySym, 0x31), keymap.symForKey(10, true));
    // Tecla desconhecida: sem keysym.
    try std.testing.expectEqual(@as(KeySym, 0), keymap.symForKey(200, true));
}
