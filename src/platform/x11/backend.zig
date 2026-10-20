// Zigway X11: backend sobre Xlib (declaracoes manuais em api.zig).
//
// Threading: afinidade com a thread criadora (Xlib nao e thread-safe por
// padrao para a mesma conexao). Auto-repeat: o init habilita detectable
// autorepeat (XKB), de modo que repeticoes chegam como KeyPress sem
// KeyRelease intermediario e sao marcadas com `repeat=true`.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const xrandr = @import("xrandr.zig");
const registry = @import("../registry.zig");
const events = @import("../../events.zig");
const input = @import("../../input.zig");
const window = @import("../../window.zig");
const types = @import("../../core/types.zig");

const SavedGeometry = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

const Entry = struct {
    slot: u32,
    win: api.Window,
    /// Geometria anterior quando fullscreen/maximized foi aplicado sem EWMH.
    saved_fullscreen: ?SavedGeometry = null,
    saved_maximized: ?SavedGeometry = null,
    /// true quando o estado atual e controlado pelo fallback de geometria.
    fullscreen_fallback: bool = false,
    maximize_fallback: bool = false,
};

/// Handler de erro de protocolo X. Por padrao a Xlib encerra o processo em
/// qualquer erro; a corrida real e: uma requisicao assincrona (ex.
/// `XStoreName`) e enviada antes de processarmos o `DestroyNotify` de uma
/// janela que o servidor acabou de destruir — a remocao de entrada fecha o
/// caminho normal, mas a janela de tempo existe. Retornar 0 mantem o
/// processo (o host) vivo. E global ao processo (a Xlib tem um unico
/// handler), sem estado proprio, e permanece instalado apos `deinit`.
fn xErrorHandler(display: ?*api.Display, event: *api.XErrorEvent) callconv(.c) c_int {
    _ = display;
    _ = event;
    return 0;
}

/// Verifica se `atom` esta na propriedade `property` (formato ATOM) da
/// janela. Usado para detectar `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`
/// sem depender de um WM especifico.
/// Espera a conexao X ficar legivel (com timeout em ms). Usado na
/// leitura da area de transferencia para nao bloquear indefinidamente
/// esperando o owner da selecao.
fn waitForXEvent(display: *api.Display, timeout_ms: i32) void {
    const fd = api.XConnectionNumber(display);
    if (fd < 0) return;
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = std.posix.poll(&fds, timeout_ms) catch {};
}

fn propertyHasAtom(
    display: *api.Display,
    target: api.Window,
    property: api.Atom,
    atom: api.Atom,
) bool {
    if (property == 0 or atom == 0) return false;
    var actual_type: api.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var raw: ?[*]u8 = null;
    const status = api.XGetWindowProperty(
        display,
        target,
        property,
        0,
        1024,
        0,
        api.XA_ATOM,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &raw,
    );
    defer {
        if (raw) |ptr| _ = api.XFree(@ptrCast(ptr));
    }
    // `XGetWindowProperty` devolve 0 mesmo em sucesso (e quando a
    // propriedade nao existe): o que indica a existencia e o tipo
    // devolvido (`None` = propriedade ausente).
    _ = status;
    if (actual_type != api.XA_ATOM or actual_format != 32) return false;
    if (nitems == 0) return false;
    // Formato 32 da Xlib e devolvido como array de `long`, nao de int.
    const values: [*]c_ulong = @ptrCast(@alignCast(raw orelse return false));
    var i: usize = 0;
    while (i < @as(usize, @intCast(nitems))) : (i += 1) {
        if (values[i] == atom) return true;
    }
    return false;
}

pub const Backend = struct {
    allocator: std.mem.Allocator,
    display: *api.Display,
    root: api.Window,
    wm_delete: api.Atom,
    wm_protocols: api.Atom,
    /// `_NET_MOVERESIZE_WINDOW` (EWMH): posicionamento absoluto com
    /// StaticGravity quando suportado pelo WM.
    net_moveresize_window: api.Atom,
    /// O WM anunciou `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`.
    net_moveresize_supported: bool = false,
    /// Atoms EWMH para fullscreen/maximize e se o WM os anuncia em
    /// `_NET_SUPPORTED`.
    net_wm_state: api.Atom,
    net_wm_state_fullscreen: api.Atom,
    net_wm_state_maximized_horz: api.Atom,
    net_wm_state_maximized_vert: api.Atom,
    net_fullscreen_supported: bool = false,
    net_maximize_supported: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    /// Cache de cursores por variante, criado sob demanda e liberado no
    /// deinit. Handles sao globais ao backend (compartilhados por janelas).
    cursors: [types.Cursor.count]api.Cursor = @splat(0),
    /// Slot da janela com grab de ponteiro (exclusivo por conexao), se
    /// houver. O servidor libera o grab quando a janela fica nao-visivel
    /// ou e destruida; os handlers de evento limpam o estado nesses casos.
    captured: ?u32 = null,
    /// libXrandr carregada em runtime (opcional). Mantida viva ate depois
    /// de XCloseDisplay: a biblioteca registra extensoes na Xlib.
    xrandr: ?xrandr.Lib = null,
    /// RandR 1.5+ disponivel, com `XRRGetMonitors` utilizavel.
    xrandr_monitors: bool = false,
    /// event_base RandR quando screen/crtc/output notifications foram
    /// selecionados no root; null sem libXrandr/simbolos.
    xrandr_event_base: ?c_int = null,
    /// Janela oculta que possui a selecao CLIPBOARD (owner). 0 quando a
    /// area de transferencia nao esta disponivel.
    clipboard_window: api.Window = 0,
    /// Atoms da area de transferencia.
    clipboard_atom: api.Atom = 0,
    utf8_string_atom: api.Atom = 0,
    targets_atom: api.Atom = 0,
    /// Alvos de texto legados/compatos (`text/plain`,
    /// `text/plain;charset=utf-8`).
    text_plain_atom: api.Atom = 0,
    text_plain_utf8_atom: api.Atom = 0,
    /// Propriedade usada nas leituras (resposta do owner).
    clipboard_property: api.Atom = 0,
    /// Texto (UTF-8) da area de transferencia; propriedade do backend.
    clipboard_text: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) !Backend {
        const display = api.XOpenDisplay(null) orelse return error.NoDisplay;
        errdefer _ = api.XCloseDisplay(display);
        // Nao deixa o handler padrao da Xlib encerrar o processo em um erro
        // de protocolo recuperavel (ver xErrorHandler).
        _ = api.XSetErrorHandler(xErrorHandler);
        // Auto-repeat: "detectable autorepeat" faz o servidor enviar apenas
        // KeyPress repetidos (sem KeyRelease no meio), o que permite marcar
        // `repeat` sem apagar o estado da tecla. Servidor sem suporte
        // devolve false em `supported`; nesse caso repeat fica false
        // (fallback igual ao comportamento anterior).
        var xkb_supported: api.XBool = 0;
        _ = api.XkbSetDetectableAutoRepeat(display, 1, &xkb_supported);
        const root = api.XDefaultRootWindow(display);
        const wm_delete = api.XInternAtom(display, "WM_DELETE_WINDOW", 0);
        if (wm_delete == 0) return error.ConnectionFailed;
        const wm_protocols = api.XInternAtom(display, "WM_PROTOCOLS", 0);
        if (wm_protocols == 0) return error.ConnectionFailed;
        const net_moveresize_window = api.XInternAtom(display, "_NET_MOVERESIZE_WINDOW", 0);
        const net_supported = api.XInternAtom(display, "_NET_SUPPORTED", 0);
        const net_moveresize_supported = propertyHasAtom(
            display,
            root,
            net_supported,
            net_moveresize_window,
        );
        const net_wm_state = api.XInternAtom(display, "_NET_WM_STATE", 0);
        const net_wm_state_fullscreen = api.XInternAtom(
            display,
            "_NET_WM_STATE_FULLSCREEN",
            0,
        );
        const net_fullscreen_supported =
            propertyHasAtom(display, root, net_supported, net_wm_state) and
            propertyHasAtom(display, root, net_supported, net_wm_state_fullscreen);
        const net_wm_state_maximized_horz = api.XInternAtom(
            display,
            "_NET_WM_STATE_MAXIMIZED_HORZ",
            0,
        );
        const net_wm_state_maximized_vert = api.XInternAtom(
            display,
            "_NET_WM_STATE_MAXIMIZED_VERT",
            0,
        );
        const net_maximize_supported =
            propertyHasAtom(display, root, net_supported, net_wm_state) and
            propertyHasAtom(display, root, net_supported, net_wm_state_maximized_horz) and
            propertyHasAtom(display, root, net_supported, net_wm_state_maximized_vert);
        // Opcional e sem dependencia de link. Carregado por ultimo: nao ha
        // mais operacoes faliveis no init, entao o errdefer do display
        // continua correto em qualquer falha anterior.
        const xrandr_lib = xrandr.Lib.load();
        var xrandr_monitors = false;
        var xrandr_event_base: ?c_int = null;
        if (xrandr_lib) |*lib| {
            xrandr_monitors = lib.supportsMonitors(display);
            xrandr_event_base = lib.enableEvents(display, root);
        }
        // Area de transferencia: atoms + janela oculta que possui a
        // selecao CLIPBOARD. Sem atoms validos, o recurso fica off.
        const clipboard_atom = api.XInternAtom(display, "CLIPBOARD", 0);
        const utf8_string_atom = api.XInternAtom(display, "UTF8_STRING", 0);
        const targets_atom = api.XInternAtom(display, "TARGETS", 0);
        const text_plain_atom = api.XInternAtom(display, "text/plain", 0);
        const text_plain_utf8_atom = api.XInternAtom(
            display,
            "text/plain;charset=utf-8",
            0,
        );
        const clipboard_property = api.XInternAtom(display, "ZIGWAY_CLIPBOARD", 0);
        var clipboard_window: api.Window = 0;
        if (clipboard_atom != 0 and utf8_string_atom != 0 and clipboard_property != 0) {
            // Janela 1x1 nunca mapeada: serve apenas de owner da selecao.
            clipboard_window = api.XCreateSimpleWindow(
                display,
                root,
                0,
                0,
                1,
                1,
                0,
                0,
                0,
            );
        }
        return .{
            .allocator = allocator,
            .display = display,
            .root = root,
            .wm_delete = wm_delete,
            .wm_protocols = wm_protocols,
            .net_moveresize_window = net_moveresize_window,
            .net_moveresize_supported = net_moveresize_supported,
            .net_wm_state = net_wm_state,
            .net_wm_state_fullscreen = net_wm_state_fullscreen,
            .net_wm_state_maximized_horz = net_wm_state_maximized_horz,
            .net_wm_state_maximized_vert = net_wm_state_maximized_vert,
            .net_fullscreen_supported = net_fullscreen_supported,
            .net_maximize_supported = net_maximize_supported,
            .xrandr = xrandr_lib,
            .xrandr_monitors = xrandr_monitors,
            .xrandr_event_base = xrandr_event_base,
            .clipboard_window = clipboard_window,
            .clipboard_atom = clipboard_atom,
            .utf8_string_atom = utf8_string_atom,
            .targets_atom = targets_atom,
            .text_plain_atom = text_plain_atom,
            .text_plain_utf8_atom = text_plain_utf8_atom,
            .clipboard_property = clipboard_property,
        };
    }

    pub fn deinit(self: *Backend) void {
        if (self.captured != null) _ = api.XUngrabPointer(self.display, api.CurrentTime);
        for (self.cursors) |handle| {
            if (handle != 0) _ = api.XFreeCursor(self.display, handle);
        }
        if (self.clipboard_text) |text| self.allocator.free(text);
        self.clipboard_text = null;
        if (self.clipboard_window != 0) {
            _ = api.XDestroyWindow(self.display, self.clipboard_window);
            self.clipboard_window = 0;
        }
        self.entries.deinit(self.allocator);
        _ = api.XCloseDisplay(self.display);
        // So depois do display: dlclose antes de XCloseDisplay deixa
        // callbacks da extensao apontando para codigo descarregado.
        if (self.xrandr) |*lib| lib.deinit();
    }

    /// Snapshot dos monitores. Com RandR 1.5+ usa `XRRGetMonitors`; caso
    /// contrario cai para as X screens (cada uma com origem 0,0). O
    /// chamador libera a slice com o mesmo alocador.
    pub fn displays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        if (self.xrandr_monitors) {
            if (self.xrandr) |*lib| {
                if (try lib.monitors(self.display, self.root, allocator)) |list| {
                    return list;
                }
            }
        }
        return self.screenDisplays(allocator);
    }

    fn screenDisplays(
        self: *const Backend,
        allocator: std.mem.Allocator,
    ) ![]types.DisplayInfo {
        const count = api.XScreenCount(self.display);
        if (count <= 0) return allocator.alloc(types.DisplayInfo, 0);
        const n: usize = @intCast(count);
        const list = try allocator.alloc(types.DisplayInfo, n);
        errdefer allocator.free(list);
        const default_screen = api.XDefaultScreen(self.display);
        for (list, 0..) |*info, i| {
            const screen: c_int = @intCast(i);
            const width = api.XDisplayWidth(self.display, screen);
            const height = api.XDisplayHeight(self.display, screen);
            info.* = .{
                .id = .{ .raw = @intCast(i) },
                // X screens tem espacos de coordenadas independentes;
                // nao ha posicao global combinada.
                .x = 0,
                .y = 0,
                .width = std.math.cast(u32, width) orelse 0,
                .height = std.math.cast(u32, height) orelse 0,
                .primary = screen == default_screen,
            };
        }
        return list;
    }

    /// Modos de video oferecidos por um display (RandR 1.5+). Lista vazia
    /// quando o backend nao expoe modos (sem libXrandr/RandR 1.5+).
    pub fn displayModes(
        self: *const Backend,
        allocator: std.mem.Allocator,
        id: types.DisplayId,
    ) ![]types.DisplayMode {
        if (!self.xrandr_monitors) return allocator.alloc(types.DisplayMode, 0);
        if (self.xrandr) |*lib| {
            const modes = try lib.monitorModes(
                self.display,
                self.root,
                id.raw,
                allocator,
            ) orelse return allocator.alloc(types.DisplayMode, 0);
            return modes;
        }
        return allocator.alloc(types.DisplayMode, 0);
    }

    /// Aplica um modo de video via RandR. Requer RandR 1.5+, um CRTC ativo
    /// no monitor e um modo oferecido pelo output.
    pub fn setDisplayMode(
        self: *const Backend,
        id: types.DisplayId,
        mode: types.DisplayModeId,
    ) !void {
        if (!mode.isValid()) return error.InvalidDisplayMode;
        if (!self.xrandr_monitors) return error.DisplayModeUnsupported;
        if (self.xrandr) |*lib| {
            try lib.setMonitorMode(self.display, self.root, id.raw, mode.raw);
            return;
        }
        return error.DisplayModeUnsupported;
    }

    // --- Area de transferencia (selecao CLIPBOARD) ---

    /// Limite de 1 MiB por texto na area de transferencia.
    pub const max_clipboard_bytes: usize = 1 << 20;
    /// Tempo maximo de espera do owner da selecao (ms).
    pub const clipboard_timeout_ms: i64 = 500;

    /// Define o texto (UTF-8) da area de transferencia e toma a posse da
    /// selecao CLIPBOARD.
    pub fn setClipboardText(self: *Backend, text: []const u8) !void {
        if (self.clipboard_window == 0) return error.ClipboardFailed;
        if (text.len > max_clipboard_bytes) return error.InvalidConfig;

        if (self.clipboard_text) |old| {
            self.allocator.free(old);
            self.clipboard_text = null;
        }
        if (text.len > 0) {
            self.clipboard_text = try self.allocator.dupe(u8, text);
        }
        _ = api.XSetSelectionOwner(
            self.display,
            self.clipboard_atom,
            self.clipboard_window,
            api.CurrentTime,
        );
        if (api.XGetSelectionOwner(self.display, self.clipboard_atom) != self.clipboard_window) {
            // Nao foi possivel tomar a selecao: desfaz o conteudo.
            if (self.clipboard_text) |old| {
                self.allocator.free(old);
                self.clipboard_text = null;
            }
            return error.ClipboardFailed;
        }
        _ = api.XFlush(self.display);
    }

    /// Texto (UTF-8) da area de transferencia. `null` quando vazia, sem
    /// texto ou quando o owner nao responde dentro do prazo.
    ///
    /// A leitura no X11 e sincrona: a conexao e bombada enquanto se
    /// espera o `SelectionNotify`. Eventos do app nesse intervalo vao
    /// para a fila normal (nenhum evento e perdido), mas a chamada
    /// bloqueia ate o timeout.
    pub fn clipboardText(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        allocator: std.mem.Allocator,
    ) !?[]u8 {
        if (self.clipboard_window == 0) return null;

        // Somos o owner: resposta imediata, sem round trip.
        if (api.XGetSelectionOwner(self.display, self.clipboard_atom) == self.clipboard_window) {
            const text = self.clipboard_text orelse return null;
            if (text.len == 0) return null;
            return try allocator.dupe(u8, text);
        }

        const requestor = self.clipboard_window;
        const property = self.clipboard_property;
        // Alvos tentados em ordem: UTF-8 e, se o owner recusar, os
        // alvos legados (o `STRING` responde em Latin-1).
        const targets = [_]api.Atom{
            self.utf8_string_atom,
            self.text_plain_utf8_atom,
            self.text_plain_atom,
            api.XA_STRING,
        };
        for (targets) |target| {
            const data = try self.requestSelectionTarget(
                reg,
                queue,
                state,
                allocator,
                requestor,
                property,
                target,
            ) orelse continue;
            if (target == api.XA_STRING) {
                // Resposta em Latin-1: converte para UTF-8.
                const converted = latin1ToUtf8(allocator, data) catch |err| {
                    allocator.free(data);
                    return err;
                };
                allocator.free(data);
                return converted;
            }
            return data;
        }
        return null;
    }

    /// Pede a selecao para um alvo e espera a resposta do owner.
    /// Retorna null quando o owner recusa o alvo ou nao responde.
    fn requestSelectionTarget(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        allocator: std.mem.Allocator,
        requestor: api.Window,
        property: api.Atom,
        target: api.Atom,
    ) !?[]u8 {
        _ = api.XDeleteProperty(self.display, requestor, property);
        _ = api.XConvertSelection(
            self.display,
            self.clipboard_atom,
            target,
            property,
            requestor,
            api.CurrentTime,
        );
        _ = api.XFlush(self.display);

        // Orcamento de tentativas: cada espera e de ate 10ms, logo o
        // limite total fica em ~clipboard_timeout_ms.
        var attempts: u32 = 0;
        const max_attempts: u32 = @intCast(clipboard_timeout_ms / 10);
        while (attempts < max_attempts) : (attempts += 1) {
            while (api.XPending(self.display) > 0) {
                var ev: api.XEvent = undefined;
                _ = api.XNextEvent(self.display, &ev);
                if (ev.type == api.SelectionNotify) {
                    const notify = ev.selection;
                    if (notify.requestor == requestor and
                        notify.selection == self.clipboard_atom and
                        notify.target == target)
                    {
                        // `property == 0`: o owner recusou o alvo.
                        if (notify.property == 0) return null;
                        return try self.readClipboardProperty(allocator, requestor, property);
                    }
                    continue;
                }
                // Eventos do app continuam o fluxo normal (fila).
                self.translate(reg, queue, state, &ev);
            }
            waitForXEvent(self.display, 10);
        }
        // Timeout: o owner nao respondeu.
        return null;
    }

    /// Le a propriedade respondida por um owner da selecao, em blocos
    /// (a resposta maxima do servidor e 256KB por pedido).
    fn readClipboardProperty(
        self: *Backend,
        allocator: std.mem.Allocator,
        requestor: api.Window,
        property: api.Atom,
    ) !?[]u8 {
        const chunk_words: c_long = 16384; // 64KB por pedido
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var offset: c_long = 0;
        while (out.items.len <= max_clipboard_bytes) {
            var actual_type: api.Atom = 0;
            var actual_format: c_int = 0;
            var nitems: c_ulong = 0;
            var bytes_after: c_ulong = 0;
            var data: ?[*]u8 = null;
            const ok = api.XGetWindowProperty(
                self.display,
                requestor,
                property,
                offset,
                chunk_words,
                0, // delete: a propriedade e removida no fim
                0, // AnyPropertyType
                &actual_type,
                &actual_format,
                &nitems,
                &bytes_after,
                &data,
            );
            defer {
                if (data) |ptr| _ = api.XFree(@ptrCast(ptr));
            }
            // `XGetWindowProperty` devolve 0 em sucesso; a existencia da
            // propriedade e indicada pelo tipo devolvido (`None` = ausente).
            _ = ok;
            if (actual_type == 0) break;
            // Texto em UTF-8: propriedade de 8 bits por byte.
            if (actual_format != 8) break;
            const bytes: usize = @intCast(nitems);
            if (bytes == 0) break;
            if (out.items.len + bytes > max_clipboard_bytes) break;
            const ptr = data orelse break;
            try out.appendSlice(allocator, ptr[0..bytes]);
            if (bytes_after == 0) break;
            // O offset e em unidades de 32 bits.
            offset += @intCast((bytes + 3) / 4);
        }
        if (out.items.len == 0) return null;
        return try out.toOwnedSlice(allocator);
    }

    /// Responde a um `SelectionRequest` (somos o owner da selecao).
    fn handleSelectionRequest(self: *Backend, req: *const api.XSelectionRequestEvent) void {
        // `property == 0` significa "use o target como propriedade".
        const property = if (req.property == 0) req.target else req.property;
        var granted = false;
        if (req.target == self.targets_atom) {
            // Alvos suportados: os de texto (UTF-8 e Latin-1) e o
            // proprio TARGETS.
            const targets = [_]u32{
                @intCast(self.targets_atom),
                @intCast(self.utf8_string_atom),
                @intCast(self.text_plain_utf8_atom),
                @intCast(self.text_plain_atom),
                @intCast(api.XA_STRING),
            };
            _ = api.XChangeProperty(
                self.display,
                req.requestor,
                property,
                api.XA_ATOM,
                32,
                api.PropModeReplace,
                @ptrCast(&targets),
                @intCast(targets.len),
            );
            granted = true;
        } else if (req.target == self.utf8_string_atom or
            req.target == self.text_plain_utf8_atom or
            req.target == self.text_plain_atom)
        {
            // UTF-8 (comportamento moderno de "text/plain").
            const text = self.clipboard_text orelse "";
            _ = api.XChangeProperty(
                self.display,
                req.requestor,
                property,
                req.target,
                8,
                api.PropModeReplace,
                if (text.len == 0) null else @ptrCast(text.ptr),
                @intCast(text.len),
            );
            granted = true;
        } else if (req.target == api.XA_STRING) {
            // `STRING` e Latin-1 (ICCCM): caracteres fora do Latin-1 viram
            // '?'.
            const text = self.clipboard_text orelse "";
            if (utf8ToLatin1(self.allocator, text)) |latin1| {
                defer self.allocator.free(latin1);
                _ = api.XChangeProperty(
                    self.display,
                    req.requestor,
                    property,
                    api.XA_STRING,
                    8,
                    api.PropModeReplace,
                    if (latin1.len == 0) null else @ptrCast(latin1.ptr),
                    @intCast(latin1.len),
                );
                granted = true;
            } else |_| {
                // Sem memoria: recusa o alvo.
            }
        }
        var notify = api.XEvent{
            .selection = .{
                .type = api.SelectionNotify,
                .serial = 0,
                .send_event = 1,
                .display = self.display,
                .requestor = req.requestor,
                .selection = req.selection,
                .target = req.target,
                // `property == 0` no aviso significa "recusado".
                .property = if (granted) property else 0,
                .time = req.time,
            },
        };
        _ = api.XSendEvent(self.display, req.requestor, 0, 0, &notify);
        _ = api.XFlush(self.display);
    }

    fn findEntry(self: *const Backend, slot: u32) ?usize {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.slot == slot) return i;
        }
        return null;
    }

    fn slotOfNative(self: *const Backend, reg: *registry.Registry, win: api.Window) ?u32 {
        for (self.entries.items) |entry| {
            if (entry.win == win) {
                if (entry.slot < reg.slots.items.len and
                    reg.slots.items[entry.slot].occupied)
                {
                    return entry.slot;
                }
                return null;
            }
        }
        return null;
    }

    pub fn createWindow(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cfg: window.WindowConfig,
    ) !void {
        var title_buf: [1025:0]u8 = undefined;
        @memcpy(title_buf[0..cfg.title.len], cfg.title);
        title_buf[cfg.title.len] = 0;

        const win = api.XCreateSimpleWindow(
            self.display,
            self.root,
            0,
            0,
            cfg.width,
            cfg.height,
            0,
            0,
            0,
        );
        if (win == api.None) return error.WindowCreationFailed;
        errdefer _ = api.XDestroyWindow(self.display, win);

        _ = api.XSelectInput(self.display, win, api.input_mask);
        _ = api.XStoreName(self.display, win, @ptrCast(&title_buf));
        var protocols = [_]api.Atom{self.wm_delete};
        _ = api.XSetWMProtocols(self.display, win, &protocols, 1);
        if (cfg.visible) _ = api.XMapWindow(self.display, win);
        _ = api.XFlush(self.display);

        try self.entries.append(self.allocator, .{ .slot = slot, .win = win });
        reg.slots.items[slot].native_id = win;
    }

    pub fn destroyWindow(self: *Backend, reg: *registry.Registry, slot: u32) void {
        // Solta o grab antes de destruir a janela (o servidor tambem
        // liberaria automaticamente, mas o estado local ficaria obsoleto).
        self.releasePointer(reg, slot);
        // Remove o registro ANTES de destruir: o DestroyNotify resultante
        // nao encontra entrada e e ignorado (sem evento espurio).
        if (self.findEntry(slot)) |i| {
            const win = self.entries.items[i].win;
            _ = self.entries.swapRemove(i);
            _ = api.XDestroyWindow(self.display, win);
            _ = api.XFlush(self.display);
        }
    }

    pub fn setTitle(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        title: []const u8,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        var title_buf: [1025:0]u8 = undefined;
        @memcpy(title_buf[0..title.len], title);
        title_buf[title.len] = 0;
        _ = api.XStoreName(self.display, self.entries.items[entry_idx].win, @ptrCast(&title_buf));
        _ = api.XFlush(self.display);
    }

    pub fn setSize(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        width: u32,
        height: u32,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        _ = api.XResizeWindow(self.display, self.entries.items[entry_idx].win, width, height);
        _ = api.XFlush(self.display);
        // Confirmacao chega via ConfigureNotify.
    }

    /// Aplica limites via `WM_NORMAL_HINTS`; preserva outros hints ja
    /// definidos. A confirmacao e local (XSetWMNormalHints nao tem erro de
    /// retorno); o WM pode ajustar a aplicacao conforme suas politicas.
    pub fn setSizeLimits(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        limits: types.WindowSizeLimits,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const win = self.entries.items[entry_idx].win;

        var hints: api.XSizeHints = std.mem.zeroes(api.XSizeHints);
        var supplied: c_long = 0;
        if (api.XGetWMNormalHints(self.display, win, &hints, &supplied) == 0) {
            hints = std.mem.zeroes(api.XSizeHints);
        }
        hints.flags &= ~(api.PMinSize | api.PMaxSize);

        if (limits.min_width != 0 or limits.min_height != 0) {
            const min_width = std.math.cast(c_int, limits.min_width) orelse
                return error.InvalidConfig;
            const min_height = std.math.cast(c_int, limits.min_height) orelse
                return error.InvalidConfig;
            hints.flags |= api.PMinSize;
            hints.min_width = min_width;
            hints.min_height = min_height;
        } else {
            hints.min_width = 0;
            hints.min_height = 0;
        }

        if (limits.max_width != 0 or limits.max_height != 0) {
            const max_width = if (limits.max_width == 0)
                std.math.maxInt(c_int)
            else
                std.math.cast(c_int, limits.max_width) orelse
                    return error.InvalidConfig;
            const max_height = if (limits.max_height == 0)
                std.math.maxInt(c_int)
            else
                std.math.cast(c_int, limits.max_height) orelse
                    return error.InvalidConfig;
            hints.flags |= api.PMaxSize;
            hints.max_width = max_width;
            hints.max_height = max_height;
        } else {
            hints.max_width = 0;
            hints.max_height = 0;
        }

        api.XSetWMNormalHints(self.display, win, &hints);

        // Round-trip: confirma que a propriedade nativa foi gravada com
        // os limites solicitados (o WM ainda pode ajustar a aplicacao).
        var verify: api.XSizeHints = std.mem.zeroes(api.XSizeHints);
        var verify_supplied: c_long = 0;
        if (api.XGetWMNormalHints(self.display, win, &verify, &verify_supplied) == 0) {
            return error.WindowStateFailed;
        }
        const want_min = limits.min_width != 0 or limits.min_height != 0;
        const want_max = limits.max_width != 0 or limits.max_height != 0;
        if (((verify.flags & api.PMinSize) != 0) != want_min) {
            return error.WindowStateFailed;
        }
        if (((verify.flags & api.PMaxSize) != 0) != want_max) {
            return error.WindowStateFailed;
        }
        if (want_min) {
            if (verify.min_width != hints.min_width or
                verify.min_height != hints.min_height)
            {
                return error.WindowStateFailed;
            }
        }
        if (want_max) {
            if (verify.max_width != hints.max_width or
                verify.max_height != hints.max_height)
            {
                return error.WindowStateFailed;
            }
        }
        _ = api.XFlush(self.display);
    }

    /// Move a origem da area de cliente para (x, y) em coordenadas de
    /// tela. Se o WM anunciar `_NET_MOVERESIZE_WINDOW` em `_NET_SUPPORTED`,
    /// usa EWMH + StaticGravity; caso contrario usa `XMoveWindow`
    /// (melhor esforco). Confirmacao via ConfigureNotify.
    pub fn setPosition(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        x: i32,
        y: i32,
    ) !void {
        _ = reg;
        _ = queue;
        _ = state;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const win = self.entries.items[entry_idx].win;

        if (self.net_moveresize_supported and self.net_moveresize_window != 0) {
            // data.l[0]: gravidade (StaticGravity) | flags (x,y) << 8 |
            // source (aplicacao) << 12. Ver EWMH 4.2.
            const flags: c_long = api.StaticGravity | (0x03 << 8) | (1 << 12);
            var event = api.XEvent{ .client = .{
                .type = api.ClientMessage,
                .serial = 0,
                .send_event = 1,
                .display = self.display,
                .window = win,
                .message_type = self.net_moveresize_window,
                .format = 32,
                .data = .{ .l = .{ flags, @intCast(x), @intCast(y), 0, 0 } },
            } };
            if (api.XSendEvent(
                self.display,
                self.root,
                0,
                api.SubstructureRedirectMask | api.SubstructureNotifyMask,
                &event,
            ) != 0) {
                _ = api.XFlush(self.display);
                return;
            }
        }

        if (api.XMoveWindow(self.display, win, x, y) == 0) {
            return error.WindowMoveFailed;
        }
        _ = api.XFlush(self.display);
    }

    /// Posicao atual da origem da area de cliente, consultada na Xlib
    /// (funciona com janelas reparented pelo WM).
    pub fn position(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) types.WindowPosition {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return .{ .x = 0, .y = 0 };
        return self.clientPosition(self.entries.items[entry_idx].win) orelse .{ .x = 0, .y = 0 };
    }

    /// Solicita fullscreen via EWMH quando suportado; caso contrario aplica
    /// geometria direta sobre a tela X padrao. No caminho EWMH o estado e
    /// confirmado por `PropertyNotify`; no fallback a aplicacao e sincrona.
    pub fn setFullscreen(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        fullscreen: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const entry = &self.entries.items[entry_idx];
        const win = entry.win;
        if (fullscreen and self.isMaximized(reg, slot)) {
            return error.WindowStateFailed;
        }

        if (self.net_fullscreen_supported and
            self.net_wm_state != 0 and
            self.net_wm_state_fullscreen != 0 and
            !entry.fullscreen_fallback)
        {
            // Nao compara com o estado atual: uma solicitacao anterior pode
            // ainda estar pendente no WM. Enviar add/remove extra e inofensivo
            // e permite cancelar um fullscreen ainda nao confirmado.
            var event = api.XEvent{
                .client = .{
                    .type = api.ClientMessage,
                    .serial = 0,
                    .send_event = 1,
                    .display = self.display,
                    .window = win,
                    .message_type = self.net_wm_state,
                    .format = 32,
                    .data = .{
                        .l = .{
                            if (fullscreen) 1 else 0,
                            @intCast(self.net_wm_state_fullscreen),
                            0,
                            1, // source: aplicacao
                            0,
                        },
                    },
                },
            };
            if (api.XSendEvent(
                self.display,
                self.root,
                0,
                api.SubstructureRedirectMask | api.SubstructureNotifyMask,
                &event,
            ) == 0) return error.WindowStateFailed;
            _ = api.XFlush(self.display);
            return;
        }

        const slot_state = &reg.slots.items[slot];
        if (fullscreen) {
            if (entry.fullscreen_fallback) return;
            const pos = self.clientPosition(win) orelse return error.WindowStateFailed;
            if (slot_state.width == 0 or slot_state.height == 0) return error.WindowStateFailed;
            const screen = api.XDefaultScreen(self.display);
            const screen_w = api.XDisplayWidth(self.display, screen);
            const screen_h = api.XDisplayHeight(self.display, screen);
            if (screen_w <= 0 or screen_h <= 0) return error.WindowStateFailed;
            const width = std.math.cast(c_uint, screen_w) orelse return error.WindowStateFailed;
            const height = std.math.cast(c_uint, screen_h) orelse return error.WindowStateFailed;
            if (api.XMoveResizeWindow(self.display, win, 0, 0, width, height) == 0) {
                return error.WindowStateFailed;
            }
            entry.saved_fullscreen = .{
                .x = pos.x,
                .y = pos.y,
                .width = slot_state.width,
                .height = slot_state.height,
            };
            entry.fullscreen_fallback = true;
            slot_state.fullscreen = true;
            _ = api.XFlush(self.display);
            events.dispatch(queue, state, .{ .fullscreen = .{
                .window = reg.idOf(slot),
                .fullscreen = true,
            } });
            return;
        }

        if (!entry.fullscreen_fallback) return;
        const saved = entry.saved_fullscreen orelse return error.WindowStateFailed;
        const width = std.math.cast(c_uint, saved.width) orelse return error.WindowStateFailed;
        const height = std.math.cast(c_uint, saved.height) orelse return error.WindowStateFailed;
        if (api.XMoveResizeWindow(self.display, win, saved.x, saved.y, width, height) == 0) {
            return error.WindowStateFailed;
        }
        entry.saved_fullscreen = null;
        entry.fullscreen_fallback = false;
        slot_state.fullscreen = false;
        _ = api.XFlush(self.display);
        events.dispatch(queue, state, .{ .fullscreen = .{
            .window = reg.idOf(slot),
            .fullscreen = false,
        } });
    }

    /// Estado atual: fallback e sincrono; EWMH consulta `_NET_WM_STATE`.
    pub fn isFullscreen(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return false;
        const entry = self.entries.items[entry_idx];
        if (entry.fullscreen_fallback) return true;
        if (!self.net_fullscreen_supported or self.net_wm_state == 0) return false;
        return propertyHasAtom(
            self.display,
            entry.win,
            self.net_wm_state,
            self.net_wm_state_fullscreen,
        );
    }

    /// Solicita maximize via EWMH (ambos os eixos); sem suporte, cobre a
    /// tela X padrao e restaura a geometria anterior. A confirmacao EWMH
    /// chega por `PropertyNotify`.
    pub fn setMaximized(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        slot: u32,
        maximized: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const entry = &self.entries.items[entry_idx];
        const win = entry.win;
        if (maximized and self.isFullscreen(reg, slot)) {
            return error.WindowStateFailed;
        }

        if (self.net_maximize_supported and
            self.net_wm_state != 0 and
            self.net_wm_state_maximized_horz != 0 and
            self.net_wm_state_maximized_vert != 0 and
            !entry.maximize_fallback)
        {
            var event = api.XEvent{
                .client = .{
                    .type = api.ClientMessage,
                    .serial = 0,
                    .send_event = 1,
                    .display = self.display,
                    .window = win,
                    .message_type = self.net_wm_state,
                    .format = 32,
                    .data = .{
                        .l = .{
                            if (maximized) 1 else 0,
                            @intCast(self.net_wm_state_maximized_horz),
                            @intCast(self.net_wm_state_maximized_vert),
                            1, // source: aplicacao
                            0,
                        },
                    },
                },
            };
            if (api.XSendEvent(
                self.display,
                self.root,
                0,
                api.SubstructureRedirectMask | api.SubstructureNotifyMask,
                &event,
            ) == 0) return error.WindowStateFailed;
            _ = api.XFlush(self.display);
            return;
        }

        const slot_state = &reg.slots.items[slot];
        if (maximized) {
            if (entry.maximize_fallback) return;
            const pos = self.clientPosition(win) orelse return error.WindowStateFailed;
            if (slot_state.width == 0 or slot_state.height == 0) {
                return error.WindowStateFailed;
            }
            const screen = api.XDefaultScreen(self.display);
            const screen_w = api.XDisplayWidth(self.display, screen);
            const screen_h = api.XDisplayHeight(self.display, screen);
            if (screen_w <= 0 or screen_h <= 0) return error.WindowStateFailed;
            const width = std.math.cast(c_uint, screen_w) orelse
                return error.WindowStateFailed;
            const height = std.math.cast(c_uint, screen_h) orelse
                return error.WindowStateFailed;
            if (api.XMoveResizeWindow(self.display, win, 0, 0, width, height) == 0) {
                return error.WindowStateFailed;
            }
            entry.saved_maximized = .{
                .x = pos.x,
                .y = pos.y,
                .width = slot_state.width,
                .height = slot_state.height,
            };
            entry.maximize_fallback = true;
            slot_state.maximized = true;
            _ = api.XFlush(self.display);
            events.dispatch(queue, state, .{ .maximized = .{
                .window = reg.idOf(slot),
                .maximized = true,
            } });
            return;
        }

        if (!entry.maximize_fallback) return;
        const saved = entry.saved_maximized orelse return error.WindowStateFailed;
        const width = std.math.cast(c_uint, saved.width) orelse
            return error.WindowStateFailed;
        const height = std.math.cast(c_uint, saved.height) orelse
            return error.WindowStateFailed;
        if (api.XMoveResizeWindow(self.display, win, saved.x, saved.y, width, height) == 0) {
            return error.WindowStateFailed;
        }
        entry.saved_maximized = null;
        entry.maximize_fallback = false;
        slot_state.maximized = false;
        _ = api.XFlush(self.display);
        events.dispatch(queue, state, .{ .maximized = .{
            .window = reg.idOf(slot),
            .maximized = false,
        } });
    }

    /// Estado atual: fallback e sincrono; EWMH exige os dois eixos.
    pub fn isMaximized(
        self: *const Backend,
        reg: *const registry.Registry,
        slot: u32,
    ) bool {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return false;
        const entry = self.entries.items[entry_idx];
        if (entry.maximize_fallback) return true;
        if (!self.net_maximize_supported or self.net_wm_state == 0) return false;
        return propertyHasAtom(
            self.display,
            entry.win,
            self.net_wm_state,
            self.net_wm_state_maximized_horz,
        ) and propertyHasAtom(
            self.display,
            entry.win,
            self.net_wm_state,
            self.net_wm_state_maximized_vert,
        );
    }

    fn clientPosition(self: *const Backend, win: api.Window) ?types.WindowPosition {
        var x: c_int = 0;
        var y: c_int = 0;
        var child: api.Window = 0;
        if (api.XTranslateCoordinates(
            self.display,
            win,
            self.root,
            0,
            0,
            &x,
            &y,
            &child,
        ) == 0) return null;
        return .{ .x = x, .y = y };
    }

    pub fn setVisible(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        visible: bool,
    ) !void {
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const win = self.entries.items[entry_idx].win;
        if (visible) {
            _ = api.XMapWindow(self.display, win);
        } else {
            _ = api.XUnmapWindow(self.display, win);
        }
        _ = api.XFlush(self.display);
        reg.slots.items[slot].visible = visible;
    }

    pub fn focusWindow(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        _ = api.XSetInputFocus(
            self.display,
            self.entries.items[entry_idx].win,
            api.RevertToParent,
            api.CurrentTime,
        );
        _ = api.XFlush(self.display);
    }

    pub fn setCursor(
        self: *Backend,
        reg: *registry.Registry,
        slot: u32,
        cursor: types.Cursor,
    ) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        const handle = try self.cursorHandle(cursor);
        if (api.XDefineCursor(self.display, self.entries.items[entry_idx].win, handle) == 0) {
            return error.CursorCreationFailed;
        }
        _ = api.XFlush(self.display);
    }

    /// Cria (uma vez) e devolve o handle nativo da variante. Falha de
    /// criacao nao e cacheada: a proxima chamada tenta de novo.
    fn cursorHandle(self: *Backend, cursor: types.Cursor) !api.Cursor {
        const idx: usize = @backingInt(cursor);
        if (self.cursors[idx] != 0) return self.cursors[idx];
        const handle = api.XCreateFontCursor(self.display, cursorShape(cursor));
        if (handle == 0) return error.CursorCreationFailed;
        self.cursors[idx] = handle;
        return handle;
    }

    pub fn capturePointer(self: *Backend, reg: *registry.Registry, slot: u32) !void {
        _ = reg;
        const entry_idx = self.findEntry(slot) orelse return error.InvalidWindow;
        if (self.captured == slot) return;
        // Captura exclusiva por conexao: transferir exige soltar a atual.
        if (self.captured != null) {
            _ = api.XUngrabPointer(self.display, api.CurrentTime);
            self.captured = null;
        }
        const status = api.XGrabPointer(
            self.display,
            self.entries.items[entry_idx].win,
            api.True,
            @intCast(api.ButtonPressMask | api.ButtonReleaseMask | api.PointerMotionMask),
            api.GrabModeAsync,
            api.GrabModeAsync,
            api.None, // confine_to: nao confina o ponteiro
            api.None, // cursor: nao altera o cursor
            api.CurrentTime,
        );
        if (status != api.GrabSuccess) return error.PointerCaptureFailed;
        self.captured = slot;
        _ = api.XFlush(self.display);
    }

    pub fn releasePointer(self: *Backend, reg: *registry.Registry, slot: u32) void {
        _ = reg;
        if (self.captured != slot) return;
        _ = api.XUngrabPointer(self.display, api.CurrentTime);
        self.captured = null;
        _ = api.XFlush(self.display);
    }

    pub fn poll(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
    ) void {
        while (api.XPending(self.display) > 0) {
            var ev: api.XEvent = undefined;
            _ = api.XNextEvent(self.display, &ev);
            self.translate(reg, queue, state, &ev);
        }
    }

    fn translate(
        self: *Backend,
        reg: *registry.Registry,
        queue: *events.EventQueue,
        state: *input.InputState,
        ev: *api.XEvent,
    ) void {
        // RandR: evento base + 0 = RRScreenChangeNotify; + 1 = RRNotify
        // (CRTC/output). Ambos significam que o snapshot de displays pode
        // ter mudado; um aviso sem payload e suficiente.
        if (self.xrandr_event_base) |base| {
            if (ev.type == base) {
                if (self.xrandr) |*lib| lib.updateConfiguration(ev);
                events.dispatch(queue, state, .{ .display_change = .{} });
                return;
            }
            if (ev.type == base + 1) {
                events.dispatch(queue, state, .{ .display_change = .{} });
                return;
            }
        }
        switch (ev.type) {
            api.KeyPress, api.KeyRelease => {
                const pressed = ev.type == api.KeyPress;
                const wid = self.windowId(reg, ev.key.window);
                const sym = api.XLookupKeysym(&ev.key, 0);
                const key = fromKeysym(sym);
                const mods = fromState(ev.key.state);
                const kev: events.KeyEvent = .{
                    .window = wid,
                    .key = key,
                    .modifiers = mods,
                    .repeat = pressed and isRepeat(state, key),
                };
                if (pressed) {
                    events.dispatch(queue, state, .{ .key_down = kev });
                    // Texto: o keysym shifted (Shift) vira codepoint
                    // Unicode. Sem IM (compose/dead keys) nao ha texto
                    // para teclas sem caractere.
                    if (wid) |window_id| {
                        const index: c_int = if (ev.key.state & api.ShiftMask != 0) 1 else 0;
                        const text_sym = api.XLookupKeysym(&ev.key, index);
                        if (keysymToCodepoint(text_sym)) |codepoint| {
                            events.dispatch(queue, state, .{ .text_input = .{
                                .window = window_id,
                                .codepoint = codepoint,
                            } });
                        }
                    }
                } else {
                    events.dispatch(queue, state, .{ .key_up = kev });
                }
                // Input bruto: o keycode do X11 e a tecla fisica
                // (codigo do evdev + 8 no Linux), independente do layout.
                if (wid) |window_id| {
                    events.dispatch(queue, state, .{ .raw_key = .{
                        .window = window_id,
                        .scancode = ev.key.keycode,
                        .pressed = pressed,
                        .modifiers = mods,
                    } });
                }
            },
            api.ButtonPress, api.ButtonRelease => {
                const pressed = ev.type == api.ButtonPress;
                const wid = self.windowId(reg, ev.button.window);
                const mods = fromState(ev.button.state);
                const x: i32 = ev.button.x;
                const y: i32 = ev.button.y;
                // Roda: somente no press gera scroll.
                if (pressed) {
                    if (ev.button.button == api.Button4) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 0, .dy = 1 } });
                        return;
                    } else if (ev.button.button == api.Button5) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 0, .dy = -1 } });
                        return;
                    } else if (ev.button.button == api.Button6) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = -1, .dy = 0 } });
                        return;
                    } else if (ev.button.button == api.Button7) {
                        events.dispatch(queue, state, .{ .scroll = .{ .window = wid, .dx = 1, .dy = 0 } });
                        return;
                    }
                } else if (ev.button.button == api.Button4 or
                    ev.button.button == api.Button5 or
                    ev.button.button == api.Button6 or
                    ev.button.button == api.Button7)
                {
                    return;
                }
                const button: types.MouseButton = switch (ev.button.button) {
                    api.Button1 => .left,
                    api.Button2 => .middle,
                    api.Button3 => .right,
                    8 => .back,
                    9 => .forward,
                    else => return,
                };
                events.dispatch(queue, state, .{ .pointer_button = .{
                    .window = wid,
                    .button = button,
                    .pressed = pressed,
                    .x = x,
                    .y = y,
                    .modifiers = mods,
                } });
            },
            api.MotionNotify => {
                const wid = self.windowId(reg, ev.motion.window);
                events.dispatch(queue, state, .{ .pointer_move = .{
                    .window = wid,
                    .x = ev.motion.x,
                    .y = ev.motion.y,
                } });
            },
            api.PropertyNotify => {
                if (ev.property.atom != self.net_wm_state) return;
                const slot = self.slotOfNative(reg, ev.property.window) orelse return;
                const entry_idx = self.findEntry(slot) orelse return;
                const native = self.entries.items[entry_idx];
                const entry = &reg.slots.items[slot];
                if (!native.fullscreen_fallback) {
                    const now_fullscreen = self.isFullscreen(reg, slot);
                    if (entry.fullscreen != now_fullscreen) {
                        entry.fullscreen = now_fullscreen;
                        events.dispatch(queue, state, .{ .fullscreen = .{
                            .window = reg.idOf(slot),
                            .fullscreen = now_fullscreen,
                        } });
                    }
                }
                if (!native.maximize_fallback) {
                    const now_maximized = self.isMaximized(reg, slot);
                    if (entry.maximized != now_maximized) {
                        entry.maximized = now_maximized;
                        events.dispatch(queue, state, .{ .maximized = .{
                            .window = reg.idOf(slot),
                            .maximized = now_maximized,
                        } });
                    }
                }
            },
            api.SelectionRequest => {
                // Outro cliente quer o conteudo da nossa selecao.
                self.handleSelectionRequest(&ev.selection_request);
            },
            api.SelectionClear => {
                // Outro cliente tomou a selecao: o conteudo nao e mais
                // nosso.
                if (ev.selection_clear.selection == self.clipboard_atom) {
                    if (self.clipboard_text) |old| {
                        self.allocator.free(old);
                        self.clipboard_text = null;
                    }
                }
            },
            api.ConfigureNotify => {
                const slot = self.slotOfNative(reg, ev.configure.window) orelse return;
                if (ev.configure.width < 0 or ev.configure.height < 0) return;
                const w: u32 = @intCast(ev.configure.width);
                const h: u32 = @intCast(ev.configure.height);
                const entry = &reg.slots.items[slot];
                if (self.clientPosition(ev.configure.window)) |pos| {
                    if (entry.x != pos.x or entry.y != pos.y) {
                        entry.x = pos.x;
                        entry.y = pos.y;
                        events.dispatch(queue, state, .{ .move = .{
                            .window = reg.idOf(slot),
                            .x = pos.x,
                            .y = pos.y,
                        } });
                    }
                }
                if (entry.width != w or entry.height != h) {
                    entry.width = w;
                    entry.height = h;
                    events.dispatch(queue, state, .{ .resize = .{
                        .window = reg.idOf(slot),
                        .width = w,
                        .height = h,
                    } });
                }
            },
            api.FocusIn, api.FocusOut => {
                const slot = self.slotOfNative(reg, ev.focus.window) orelse return;
                const focused = ev.type == api.FocusIn;
                reg.slots.items[slot].focused = focused;
                const wid = reg.idOf(slot);
                events.dispatch(queue, state, .{ .focus = .{
                    .window = wid,
                    .focused = focused,
                } });
                // Perda de foco libera o que estava pressionado: o SO nao
                // entregara os key_up/button_up correspondentes.
                if (!focused) input.releaseAll(wid, queue, state);
            },
            api.ClientMessage => {
                if (ev.client.format != 32) return;
                if (ev.client.message_type != self.wm_protocols) return;
                const slot = self.slotOfNative(reg, ev.client.window) orelse return;
                // Protocolo WM_DELETE_WINDOW (atomos registrados no init).
                const proto: api.Atom = @bitCast(ev.client.data.l[0]);
                if (proto == self.wm_delete) {
                    events.dispatch(queue, state, .{ .close = .{ .window = reg.idOf(slot) } });
                }
            },
            api.DestroyNotify => {
                const slot = self.slotOfNative(reg, ev.destroy.window) orelse return;
                // Janela destruida pelo servidor: marca fechamento para que
                // o consumidor encerre e libere o slot.
                reg.slots.items[slot].should_close = true;
                // O servidor libera o grab junto com a janela.
                if (self.captured == slot) self.captured = null;
                const wid = reg.idOf(slot);
                events.dispatch(queue, state, .{ .close = .{ .window = wid } });
                // Remove a entrada: a nativa morreu; operacoes seguintes
                // retornam InvalidWindow em vez de atingir XID invalida
                // (BadWindow encerra o processo no handler padrao).
                if (self.findEntry(slot)) |i| {
                    _ = self.entries.swapRemove(i);
                }
            },
            api.MapNotify => {
                const slot = self.slotOfNative(reg, ev.map.window) orelse return;
                reg.slots.items[slot].visible = true;
            },
            api.UnmapNotify => {
                const slot = self.slotOfNative(reg, ev.unmap.window) orelse return;
                reg.slots.items[slot].visible = false;
                // XGrabPointer exige janela viewable: o servidor libera o
                // grab ao desmapear; o estado local acompanha.
                if (self.captured == slot) self.captured = null;
            },
            else => {},
        }
    }

    fn windowId(
        self: *const Backend,
        reg: *registry.Registry,
        win: api.Window,
    ) ?types.WindowId {
        const slot = self.slotOfNative(reg, win) orelse return null;
        return reg.idOf(slot);
    }
};

/// Auto-repeat: com detectable autorepeat ligado, o servidor omite o
/// KeyRelease entre repeticoes, entao um KeyPress de uma tecla mapeada que
/// ja esta pressionada e repeticao. `.unknown` agrupa teclas distintas nao
/// mapeadas e por isso nunca e tratado como repeticao (evita marcar uma
/// tecla diferente como repeat).
pub fn isRepeat(state: *const input.InputState, key: types.Key) bool {
    if (key == .unknown) return false;
    return state.isKeyDown(key);
}

/// Forma nativa (cursorfont.h) de cada variante logica. Pura e testavel
/// sem display. `.not_allowed` usa XC_X_cursor (o cursorfont nao tem uma
/// forma "proibido" dedicada).
pub fn cursorShape(cursor: types.Cursor) c_uint {
    return switch (cursor) {
        .default => api.XC_left_ptr,
        .text => api.XC_xterm,
        .crosshair => api.XC_crosshair,
        .hand => api.XC_hand2,
        .resize_horizontal => api.XC_sb_h_double_arrow,
        .resize_vertical => api.XC_sb_v_double_arrow,
        .resize_all => api.XC_fleur,
        .not_allowed => api.XC_X_cursor,
        .wait => api.XC_watch,
    };
}

pub fn fromState(state: c_uint) types.Modifiers {
    return .{
        .shift = (state & api.ShiftMask) != 0,
        .control = (state & api.ControlMask) != 0,
        .alt = (state & api.Mod1Mask) != 0,
        .super = (state & api.Mod4Mask) != 0,
    };
}

/// Converte UTF-8 em Latin-1 (alvo `STRING` do ICCCM): caracteres fora
/// do Latin-1 viram '?'.
pub fn utf8ToLatin1(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            // Byte invalido: substitui e avanca um byte.
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            try out.append(allocator, '?');
            i += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(text[i .. i + len]) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (codepoint < 0x100) {
            try out.append(allocator, @intCast(codepoint));
        } else {
            try out.append(allocator, '?');
        }
        i += len;
    }
    return try out.toOwnedSlice(allocator);
}

/// Converte bytes Latin-1 em UTF-8.
pub fn latin1ToUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (bytes) |byte| {
        if (byte < 0x80) {
            try out.append(allocator, byte);
        } else {
            try out.append(allocator, 0xC0 | (byte >> 6));
            try out.append(allocator, 0x80 | (byte & 0x3F));
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Converte um keysym X11 em codepoint Unicode.
///
/// Faixas do keysym (X11): 0x20-0x7E (ASCII), 0xA0-0xFF (Latin-1) e
/// 0x01000000-0x0110FFFF (Unicode direto, bit 24 marcado). Teclas sem
/// caractere (funcoes, modificadores) nao produzem texto.
pub fn keysymToCodepoint(sym: api.KeySym) ?u32 {
    if (sym == 0) return null;
    if (sym >= 0x20 and sym <= 0x7E) return @intCast(sym);
    if (sym >= 0xA0 and sym <= 0xFF) return @intCast(sym);
    if (sym >= 0x0100_0000 and sym <= 0x0110_FFFF) {
        return @intCast(sym & 0x00FF_FFFF);
    }
    return null;
}

pub fn fromKeysym(sym: api.KeySym) types.Key {
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
    if (sym >= api.XK_F1 and sym < api.XK_F1 + 12) {
        return switch (sym - api.XK_F1) {
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
    if (sym >= api.XK_KP_0 and sym <= api.XK_KP_0 + 9) {
        return switch (sym - api.XK_KP_0) {
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
        api.XK_Escape => .escape,
        api.XK_Tab => .tab,
        api.XK_Return => .enter,
        api.XK_BackSpace => .backspace,
        api.XK_Delete => .delete,
        api.XK_Insert => .insert,
        api.XK_Home => .home,
        api.XK_End => .end,
        api.XK_Page_Up => .page_up,
        api.XK_Page_Down => .page_down,
        api.XK_Left => .left,
        api.XK_Up => .up,
        api.XK_Right => .right,
        api.XK_Down => .down,
        api.XK_Shift_L => .left_shift,
        api.XK_Shift_R => .right_shift,
        api.XK_Control_L => .left_control,
        api.XK_Control_R => .right_control,
        api.XK_Caps_Lock => .caps_lock,
        api.XK_Num_Lock => .num_lock,
        api.XK_KP_Enter => .enter,
        api.XK_KP_Home => .home,
        api.XK_KP_Left => .left,
        api.XK_KP_Up => .up,
        api.XK_KP_Right => .right,
        api.XK_KP_Down => .down,
        api.XK_KP_Prior => .page_up,
        api.XK_KP_Next => .page_down,
        api.XK_KP_End => .end,
        api.XK_KP_Insert => .insert,
        api.XK_KP_Delete => .delete,
        api.XK_Alt_L => .left_alt,
        api.XK_Alt_R => .right_alt,
        api.XK_Super_L => .left_super,
        api.XK_Super_R => .right_super,
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
    try std.testing.expectEqual(types.Key.escape, fromKeysym(api.XK_Escape));
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x61));
    try std.testing.expectEqual(types.Key.a, fromKeysym(0x41));
    try std.testing.expectEqual(types.Key.z, fromKeysym(0x7a));
    try std.testing.expectEqual(types.Key.n5, fromKeysym(0x35));
    try std.testing.expectEqual(types.Key.f1, fromKeysym(api.XK_F1));
    try std.testing.expectEqual(types.Key.f12, fromKeysym(api.XK_F1 + 11));
    try std.testing.expectEqual(types.Key.left, fromKeysym(api.XK_Left));
    try std.testing.expectEqual(types.Key.left_super, fromKeysym(api.XK_Super_L));
    try std.testing.expectEqual(types.Key.space, fromKeysym(0x20));
    try std.testing.expectEqual(types.Key.unknown, fromKeysym(0x1234));
}

test "keysym to codepoint covers ascii, latin1 and unicode" {
    // Sem texto.
    try std.testing.expectEqual(@as(?u32, null), keysymToCodepoint(0));
    try std.testing.expectEqual(@as(?u32, null), keysymToCodepoint(0xFF0B)); // XK_F1
    try std.testing.expectEqual(@as(?u32, null), keysymToCodepoint(0x0100_0000 - 1));

    // ASCII.
    try std.testing.expectEqual(@as(?u32, 0x20), keysymToCodepoint(0x20)); // espaco
    try std.testing.expectEqual(@as(?u32, 0x61), keysymToCodepoint(0x61)); // 'a'
    try std.testing.expectEqual(@as(?u32, 0x7E), keysymToCodepoint(0x7E)); // '~'

    // Latin-1.
    try std.testing.expectEqual(@as(?u32, 0xE4), keysymToCodepoint(0xE4)); // a-dieresis

    // Unicode direto (bit 24).
    try std.testing.expectEqual(@as(?u32, 0x4E2D), keysymToCodepoint(0x0100_0000 | 0x4E2D));
    try std.testing.expectEqual(@as(?u32, 0x10FFFF), keysymToCodepoint(0x0110_FFFF));
}

test "utf8 to latin1 replaces unrepresentable characters" {
    const alloc = std.testing.allocator;

    const ascii = try utf8ToLatin1(alloc, "abc");
    defer alloc.free(ascii);
    try std.testing.expectEqualStrings("abc", ascii);

    // "cafe" com acento (e-acute) cabe no Latin-1.
    const accented = try utf8ToLatin1(alloc, "caf\xc3\xa9");
    defer alloc.free(accented);
    try std.testing.expectEqualStrings("caf\xe9", accented);

    // CJK nao cabe: vira '?'.
    const cjk = try utf8ToLatin1(alloc, "\xe4\xbd\xa0");
    defer alloc.free(cjk);
    try std.testing.expectEqualStrings("?", cjk);
}

test "latin1 to utf8 encodes high bytes as two bytes" {
    const alloc = std.testing.allocator;

    const utf8 = try latin1ToUtf8(alloc, "caf\xe9");
    defer alloc.free(utf8);
    try std.testing.expectEqualStrings("caf\xc3\xa9", utf8);

    const ascii = try latin1ToUtf8(alloc, "abc");
    defer alloc.free(ascii);
    try std.testing.expectEqualStrings("abc", ascii);
}

test "cursor shapes map to cursorfont constants" {
    try std.testing.expectEqual(api.XC_left_ptr, cursorShape(.default));
    try std.testing.expectEqual(api.XC_xterm, cursorShape(.text));
    try std.testing.expectEqual(api.XC_crosshair, cursorShape(.crosshair));
    try std.testing.expectEqual(api.XC_hand2, cursorShape(.hand));
    try std.testing.expectEqual(api.XC_sb_h_double_arrow, cursorShape(.resize_horizontal));
    try std.testing.expectEqual(api.XC_sb_v_double_arrow, cursorShape(.resize_vertical));
    try std.testing.expectEqual(api.XC_fleur, cursorShape(.resize_all));
    try std.testing.expectEqual(api.XC_X_cursor, cursorShape(.not_allowed));
    try std.testing.expectEqual(api.XC_watch, cursorShape(.wait));
}

test "numpad keysyms match win32 logical keys" {
    // Com NumLock: digitos.
    try std.testing.expectEqual(types.Key.n0, fromKeysym(api.XK_KP_0));
    try std.testing.expectEqual(types.Key.n5, fromKeysym(api.XK_KP_0 + 5));
    try std.testing.expectEqual(types.Key.n9, fromKeysym(api.XK_KP_0 + 9));
    try std.testing.expectEqual(types.Key.enter, fromKeysym(api.XK_KP_Enter));
    // Sem NumLock: navegacao (mesmo resultado do Win32 com NumLock off).
    try std.testing.expectEqual(types.Key.home, fromKeysym(api.XK_KP_Home));
    try std.testing.expectEqual(types.Key.left, fromKeysym(api.XK_KP_Left));
    try std.testing.expectEqual(types.Key.up, fromKeysym(api.XK_KP_Up));
    try std.testing.expectEqual(types.Key.right, fromKeysym(api.XK_KP_Right));
    try std.testing.expectEqual(types.Key.down, fromKeysym(api.XK_KP_Down));
    try std.testing.expectEqual(types.Key.page_up, fromKeysym(api.XK_KP_Prior));
    try std.testing.expectEqual(types.Key.page_down, fromKeysym(api.XK_KP_Next));
    try std.testing.expectEqual(types.Key.end, fromKeysym(api.XK_KP_End));
    try std.testing.expectEqual(types.Key.insert, fromKeysym(api.XK_KP_Insert));
    try std.testing.expectEqual(types.Key.delete, fromKeysym(api.XK_KP_Delete));
}

test "repeat detection flags a second key_down of a mapped key" {
    var state = input.InputState{};
    const id: types.WindowId = .{ .index = 0, .generation = 0 };

    try std.testing.expect(!isRepeat(&state, .a));
    state.apply(.{ .key_down = .{
        .window = id,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });
    // Mesma tecla pressionada: repeticao. Outra tecla: nao.
    try std.testing.expect(isRepeat(&state, .a));
    try std.testing.expect(!isRepeat(&state, .b));
    // `.unknown` agrupa teclas distintas; nunca vira repeticao.
    try std.testing.expect(!isRepeat(&state, .unknown));

    state.apply(.{ .key_up = .{
        .window = id,
        .key = .a,
        .modifiers = .{},
        .repeat = false,
    } });
    try std.testing.expect(!isRepeat(&state, .a));
}

test "state mask maps modifiers" {
    const mods = fromState(api.ShiftMask | api.ControlMask | api.Mod1Mask | api.Mod4Mask);
    try std.testing.expect(mods.shift and mods.control and mods.alt and mods.super);
    const none = fromState(0);
    try std.testing.expect(!none.shift and !none.control and !none.alt and !none.super);
}

test "xevent union matches C long pad" {
    // Xlib define `long pad[24]`: 192 bytes onde C long tem 8 bytes
    // (LP64 Unix), 96 onde tem 4 (Windows LLP64; o backend X11 nunca
    // executa la, mas os tipos compilam em qualquer alvo).
    const expected: usize = if (builtin.os.tag == .windows) 96 else 192;
    try std.testing.expectEqual(expected, @sizeOf(api.XEvent));
}

test "xerror event layout matches LP64" {
    // XErrorEvent (Xlib.h): int + Display* + XID(long) + ulong + 3 uchar
    // -> 40 bytes em LP64. No Windows nao executa (X11 e Linux-only).
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(api.XErrorEvent));
    }
}

test "xerror handler swallows protocol errors" {
    // Deve retornar 0 (a Xlib segue) em vez de encerrar o processo.
    var ev = std.mem.zeroes(api.XErrorEvent);
    try std.testing.expectEqual(@as(c_int, 0), xErrorHandler(null, &ev));
}
