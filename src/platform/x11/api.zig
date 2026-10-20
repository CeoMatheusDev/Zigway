// Zigway X11: declaracoes manuais da ABI Xlib (sem @cImport).
//
// Layouts conferidos contra /usr/include/X11/Xlib.h (x86_64-linux:
// int=4, long=8, ponteiro=8). Tipos C mapeados:
//   int -> c_int | unsigned long -> c_ulong | Bool -> c_int
//   Window/Atom/Time/KeySym -> c_ulong | char -> c_char

pub const Display = opaque {};

pub const Window = c_ulong;
pub const Atom = c_ulong;
pub const Time = c_ulong;
pub const KeySym = c_ulong;
pub const Cursor = c_ulong;
pub const XBool = c_int;
pub const True: c_int = 1;
pub const Status = c_int;

pub const None: Window = 0;
pub const CurrentTime: Time = 0;
pub const RevertToParent: c_int = 2;
pub const XA_ATOM: Atom = 4;

/// Gravidade "estatica": referencia e o topo-esquerdo da area de cliente
/// (ICCCM/EWMH). Usada em `_NET_MOVERESIZE_WINDOW`.
pub const StaticGravity: c_long = 10;

// --- Grab de ponteiro (X.h) ---
pub const GrabModeAsync: c_int = 1;
pub const GrabSuccess: c_int = 0;

// --- Formas de cursor (cursorfont.h) ---
pub const XC_X_cursor: c_uint = 0;
pub const XC_crosshair: c_uint = 34;
pub const XC_fleur: c_uint = 52;
pub const XC_hand2: c_uint = 60;
pub const XC_left_ptr: c_uint = 68;
pub const XC_sb_h_double_arrow: c_uint = 108;
pub const XC_sb_v_double_arrow: c_uint = 116;
pub const XC_watch: c_uint = 150;
pub const XC_xterm: c_uint = 152;

// --- Tipos de evento (X.h) ---
pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ButtonPress: c_int = 4;
pub const ButtonRelease: c_int = 5;
pub const MotionNotify: c_int = 6;
pub const EnterNotify: c_int = 7;
pub const LeaveNotify: c_int = 8;
pub const FocusIn: c_int = 9;
pub const FocusOut: c_int = 10;
pub const Expose: c_int = 12;
pub const DestroyNotify: c_int = 17;
pub const UnmapNotify: c_int = 18;
pub const MapNotify: c_int = 19;
pub const ConfigureNotify: c_int = 22;
pub const ClientMessage: c_int = 33;

// --- Mascaras de evento ---
pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const ButtonPressMask: c_long = 1 << 2;
pub const ButtonReleaseMask: c_long = 1 << 3;
pub const PointerMotionMask: c_long = 1 << 6;
pub const ExposureMask: c_long = 1 << 15;
pub const StructureNotifyMask: c_long = 1 << 17;
pub const SubstructureNotifyMask: c_long = 1 << 19;
pub const SubstructureRedirectMask: c_long = 1 << 20;
pub const FocusChangeMask: c_long = 1 << 21;

pub const input_mask: c_long = KeyPressMask | KeyReleaseMask |
    ButtonPressMask | ButtonReleaseMask | PointerMotionMask |
    ExposureMask | StructureNotifyMask | FocusChangeMask;

// --- Botoes ---
pub const Button1: c_uint = 1;
pub const Button2: c_uint = 2;
pub const Button3: c_uint = 3;
pub const Button4: c_uint = 4; // roda: cima
pub const Button5: c_uint = 5; // roda: baixo
pub const Button6: c_uint = 6; // roda: esquerda
pub const Button7: c_uint = 7; // roda: direita

// --- Modificadores (mascara `state`) ---
pub const ShiftMask: c_uint = 1 << 0;
pub const ControlMask: c_uint = 1 << 2;
pub const Mod1Mask: c_uint = 1 << 3; // Alt
pub const Mod4Mask: c_uint = 1 << 6; // Super

// --- KeySyms (X11/keysymdef.h) ---
pub const XK_BackSpace: KeySym = 0xff08;
pub const XK_Tab: KeySym = 0xff09;
pub const XK_Return: KeySym = 0xff0d;
pub const XK_Escape: KeySym = 0xff1b;
pub const XK_Home: KeySym = 0xff50;
pub const XK_Left: KeySym = 0xff51;
pub const XK_Up: KeySym = 0xff52;
pub const XK_Right: KeySym = 0xff53;
pub const XK_Down: KeySym = 0xff54;
pub const XK_Page_Up: KeySym = 0xff55;
pub const XK_Page_Down: KeySym = 0xff56;
pub const XK_End: KeySym = 0xff57;
pub const XK_Insert: KeySym = 0xff63;
pub const XK_Delete: KeySym = 0xffff;
pub const XK_Shift_L: KeySym = 0xffe1;
pub const XK_Shift_R: KeySym = 0xffe2;
pub const XK_Control_L: KeySym = 0xffe3;
pub const XK_Control_R: KeySym = 0xffe4;
pub const XK_Caps_Lock: KeySym = 0xffe5;
pub const XK_Alt_L: KeySym = 0xffe9;
pub const XK_Alt_R: KeySym = 0xffea;
pub const XK_Super_L: KeySym = 0xffeb;
pub const XK_Super_R: KeySym = 0xffec;
pub const XK_Num_Lock: KeySym = 0xff7f;
pub const XK_F1: KeySym = 0xffbe;
// Teclado numerico (keysymdef.h). Com NumLock ligado chegam XK_KP_0..9;
// desligado, o servidor entrega as chaves de navegacao XK_KP_Home etc.
pub const XK_KP_Enter: KeySym = 0xff8d;
pub const XK_KP_Home: KeySym = 0xff95;
pub const XK_KP_Left: KeySym = 0xff96;
pub const XK_KP_Up: KeySym = 0xff97;
pub const XK_KP_Right: KeySym = 0xff98;
pub const XK_KP_Down: KeySym = 0xff99;
pub const XK_KP_Prior: KeySym = 0xff9a;
pub const XK_KP_Next: KeySym = 0xff9b;
pub const XK_KP_End: KeySym = 0xff9c;
pub const XK_KP_Insert: KeySym = 0xff9e;
pub const XK_KP_Delete: KeySym = 0xff9f;
pub const XK_KP_0: KeySym = 0xffb0;

// --- Estruturas (ordem e tipos identicos a Xlib.h) ---

pub const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
};

pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: XBool,
};

pub const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: XBool,
};

pub const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: c_char,
    same_screen: XBool,
};

pub const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: XBool,
};

pub const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]c_char,
        s: [10]c_short,
        l: [5]c_long,
    },
};

pub const XDestroyWindowEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    event: Window,
    window: Window,
};

pub const XFocusChangeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    window: Window,
    mode: c_int,
    detail: c_int,
};

pub const XMapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    event: Window,
    window: Window,
    override_redirect: XBool,
};

pub const XUnmapEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: XBool,
    display: ?*Display,
    event: Window,
    window: Window,
    from_configure: XBool,
};

/// Erro de protocolo X (async). Layout conferido contra
/// /usr/include/X11/Xlib.h (XErrorEvent): 40 bytes em LP64.
pub const XErrorEvent = extern struct {
    type: c_int,
    display: ?*Display,
    resourceid: Window, // XID
    serial: c_ulong,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};

/// `int (*XErrorHandler)(Display*, XErrorEvent*)`. Retornar 0 faz a Xlib
/// seguir; o handler padrao encerra o processo.
pub const XErrorHandler = *const fn (display: ?*Display, event: *XErrorEvent) callconv(.c) c_int;

/// Uniao de eventos Xlib: 24 longs (192 bytes em 64-bit).
pub const XEvent = extern union {
    type: c_int,
    pad: [24]c_long,
    any: XAnyEvent,
    key: XKeyEvent,
    button: XButtonEvent,
    motion: XMotionEvent,
    configure: XConfigureEvent,
    client: XClientMessageEvent,
    destroy: XDestroyWindowEvent,
    focus: XFocusChangeEvent,
    map: XMapEvent,
    unmap: XUnmapEvent,
};

// --- Funcoes Xlib utilizadas ---

pub extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
pub extern "X11" fn XCloseDisplay(display: *Display) c_int;
pub extern "X11" fn XDefaultScreen(display: *Display) c_int;
pub extern "X11" fn XScreenCount(display: *Display) c_int;
pub extern "X11" fn XDisplayWidth(display: *Display, screen: c_int) c_int;
pub extern "X11" fn XDisplayHeight(display: *Display, screen: c_int) c_int;
pub extern "X11" fn XDefaultRootWindow(display: *Display) Window;
pub extern "X11" fn XCreateSimpleWindow(
    display: *Display,
    parent: Window,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
    border_width: c_uint,
    border: c_ulong,
    background: c_ulong,
) Window;
pub extern "X11" fn XDestroyWindow(display: *Display, window: Window) c_int;
pub extern "X11" fn XMapWindow(display: *Display, window: Window) c_int;
pub extern "X11" fn XUnmapWindow(display: *Display, window: Window) c_int;
pub extern "X11" fn XStoreName(display: *Display, window: Window, name: [*:0]const u8) c_int;
pub extern "X11" fn XSelectInput(display: *Display, window: Window, event_mask: c_long) c_int;
pub extern "X11" fn XPending(display: *Display) c_int;
pub extern "X11" fn XNextEvent(display: *Display, event: *XEvent) c_int;
pub extern "X11" fn XFlush(display: *Display) c_int;
pub extern "X11" fn XSync(display: *Display, discard: XBool) c_int;
pub extern "X11" fn XInternAtom(display: *Display, name: [*:0]const u8, only_if_exists: XBool) Atom;
pub extern "X11" fn XSetWMProtocols(display: *Display, window: Window, protocols: [*]Atom, count: c_int) Status;
pub extern "X11" fn XResizeWindow(display: *Display, window: Window, width: c_uint, height: c_uint) c_int;
pub extern "X11" fn XMoveWindow(display: *Display, window: Window, x: c_int, y: c_int) c_int;
pub extern "X11" fn XTranslateCoordinates(
    display: *Display,
    src_window: Window,
    dest_window: Window,
    src_x: c_int,
    src_y: c_int,
    dest_x_return: *c_int,
    dest_y_return: *c_int,
    child_return: *Window,
) XBool;
pub extern "X11" fn XSendEvent(
    display: *Display,
    window: Window,
    propagate: XBool,
    event_mask: c_long,
    event: *XEvent,
) Status;
pub extern "X11" fn XGetWindowProperty(
    display: *Display,
    window: Window,
    property: Atom,
    long_offset: c_long,
    long_length: c_long,
    delete: XBool,
    req_type: Atom,
    actual_type_return: *Atom,
    actual_format_return: *c_int,
    nitems_return: *c_ulong,
    bytes_after_return: *c_ulong,
    prop_return: *?[*]u8,
) c_int;
pub extern "X11" fn XFree(data: ?*anyopaque) c_int;
pub extern "X11" fn XSetInputFocus(display: *Display, window: Window, revert_to: c_int, time: Time) c_int;
pub extern "X11" fn XCreateFontCursor(display: *Display, shape: c_uint) Cursor;
pub extern "X11" fn XDefineCursor(display: *Display, window: Window, cursor: Cursor) c_int;
pub extern "X11" fn XFreeCursor(display: *Display, cursor: Cursor) c_int;
pub extern "X11" fn XGrabPointer(
    display: *Display,
    grab_window: Window,
    owner_events: XBool,
    event_mask: c_uint,
    pointer_mode: c_int,
    keyboard_mode: c_int,
    confine_to: Window,
    cursor: Cursor,
    time: Time,
) c_int;
pub extern "X11" fn XUngrabPointer(display: *Display, time: Time) c_int;
pub extern "X11" fn XLookupKeysym(event: *const XKeyEvent, index: c_int) KeySym;
pub extern "X11" fn XSetErrorHandler(handler: XErrorHandler) XErrorHandler;
/// Habilita "detectable autorepeat" (XKB, parte da Xlib): o servidor
/// passa a enviar apenas KeyPress repetidos, sem o par
/// KeyRelease/KeyPress entre repeticoes. Assinatura conferida em
/// /usr/include/X11/XKBlib.h: `Bool (Display*, Bool, Bool*)`.
pub extern "X11" fn XkbSetDetectableAutoRepeat(
    display: *Display,
    detectable: XBool,
    supported: ?*XBool,
) XBool;
