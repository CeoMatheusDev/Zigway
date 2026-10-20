// Zigway Win32: declaracoes manuais da ABI Win32 (sem @cImport).
//
// Convenções: x86_64-windows usa a mesma convencao de chamada que C para
// as APIs (a diferenca stdcall so importa em x86-32); callbacks usam
// `callconv(.winapi)`. Handles sao ponteiros opacos. Tamanhos conferidos
// para 64-bit: HANDLE=8, UINT=4, DWORD=4(u32), LONG=4(i32).

const std = @import("std");

pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HMONITOR = ?*anyopaque;

pub const UINT = c_uint;
pub const DWORD = u32;
pub const LONG = i32;
pub const WORD = u16;
pub const ATOM = u16;
pub const BOOL = c_int;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LPCWSTR = ?[*:0]const u16;

pub const WNDPROC = *const fn (
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;

pub const MONITORENUMPROC = *const fn (
    monitor: HMONITOR,
    hdc: HDC,
    rect: *RECT,
    data: LPARAM,
) callconv(.winapi) BOOL;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

/// `MINMAXINFO` (winuser.h), usado por `WM_GETMINMAXINFO`.
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

/// `MONITORINFO` (winuser.h): cbSize + retangulo do monitor + area de
/// trabalho + flags.
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub const MONITORINFOF_PRIMARY: DWORD = 0x00000001;
pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

/// `CF_UNICODETEXT` (winuser.h): formato de texto Unicode da area de
/// transferencia.
pub const CF_UNICODETEXT: UINT = 13;
/// `GMEM_MOVEABLE` (winbase.h): alocacao movevel do kernel32.
pub const GMEM_MOVEABLE: UINT = 0x0002;

/// `CCHDEVICENAME` (wingdi.h): tamanho do nome do dispositivo de display.
pub const CCHDEVICENAME: usize = 32;
/// `CCHFORMNAME` (wingdi.h): tamanho do nome do modo ("form name").
pub const CCHFORMNAME: usize = 32;

/// `POINTL` (wingdi.h).
pub const POINTL = extern struct {
    x: LONG,
    y: LONG,
};

/// `MONITORINFOEXW` (winuser.h): `MONITORINFO` + nome do dispositivo de
/// display (ex.: `\\.\DISPLAY1`).
pub const MONITORINFOEXW = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
    szDevice: [CCHDEVICENAME]u16,
};

/// `DEVMODEW` (wingdi.h): descricao de um modo de display.
///
/// A uniao do header (orientacao de papel x `dmDisplayOrientation`/
/// `dmDisplayFixedOutput`) e representada pela variante de display, que e
/// a usada por `EnumDisplaySettings`/`ChangeDisplaySettingsEx`.
pub const DEVMODEW = extern struct {
    dmDeviceName: [CCHDEVICENAME]u16,
    dmSpecVersion: WORD,
    dmDriverVersion: WORD,
    dmSize: WORD,
    dmDriverExtra: WORD,
    dmFields: DWORD,
    dmPosition: POINTL,
    dmDisplayOrientation: DWORD,
    dmDisplayFixedOutput: DWORD,
    dmColor: i16,
    dmDuplex: i16,
    dmYResolution: i16,
    dmTTOption: i16,
    dmCollate: i16,
    dmFormName: [CCHFORMNAME]u16,
    dmLogPixels: WORD,
    dmBitsPerPel: DWORD,
    dmPelsWidth: DWORD,
    dmPelsHeight: DWORD,
    dmDisplayFlags: DWORD,
    dmDisplayFrequency: DWORD,
    dmICMMethod: DWORD,
    dmICMIntent: DWORD,
    dmMediaType: DWORD,
    dmDitherType: DWORD,
    dmReserved1: DWORD,
    dmReserved2: DWORD,
    dmPanningWidth: DWORD,
    dmPanningHeight: DWORD,
};

/// `ENUM_CURRENT_SETTINGS` (wingdi.h): modo corrente do dispositivo.
pub const ENUM_CURRENT_SETTINGS: DWORD = 0xFFFFFFFF;

/// Campos validos de `DEVMODEW.dmFields`.
pub const DM_BITSPERPEL: DWORD = 0x00040000;
pub const DM_PELSWIDTH: DWORD = 0x00080000;
pub const DM_PELSHEIGHT: DWORD = 0x00100000;
pub const DM_DISPLAYFREQUENCY: DWORD = 0x00400000;

/// Retornos de `ChangeDisplaySettingsExW`.
pub const DISP_CHANGE_SUCCESSFUL: LONG = 0;
pub const DISP_CHANGE_RESTART: LONG = 1;
pub const DISP_CHANGE_FAILED: LONG = -1;

/// CREATESTRUCTW parcial: apenas o primeiro campo e lido.
pub const CREATESTRUCT_HEAD = extern struct {
    lpCreateParams: ?*anyopaque,
};

// --- Estilos de classe/janela ---
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00100000;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_OVERLAPPED_NONRESIZABLE: DWORD = 0x00CA0000;
pub const WS_POPUP: DWORD = 0x80000000;

pub const SW_HIDE: c_int = 0;
pub const SW_SHOW: c_int = 5;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;

pub const PM_REMOVE: UINT = 0x0001;
pub const GWLP_USERDATA: c_int = -21;
pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;

pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;

pub const SIZE_RESTORED: WPARAM = 0;
pub const SIZE_MINIMIZED: WPARAM = 1;
pub const SIZE_MAXIMIZED: WPARAM = 2;

/// LOWORD(lParam) de WM_SETCURSOR quando o ponteiro esta na area de cliente.
pub const HTCLIENT: usize = 1;

pub const IDC_ARROW: usize = 32512;
pub const IDC_IBEAM: usize = 32513;
pub const IDC_WAIT: usize = 32514;
pub const IDC_CROSS: usize = 32515;
pub const IDC_SIZEWE: usize = 32644;
pub const IDC_SIZENS: usize = 32645;
pub const IDC_SIZEALL: usize = 32646;
pub const IDC_NO: usize = 32648;
pub const IDC_HAND: usize = 32649;

// --- Mensagens ---
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_XBUTTONDOWN: UINT = 0x020B;
pub const WM_XBUTTONUP: UINT = 0x020C;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;

pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;

pub const XBUTTON1: WORD = 0x0001;
pub const XBUTTON2: WORD = 0x0002;

pub const WHEEL_DELTA: i16 = 120;

// --- Teclas virtuais (VK) ---
pub const VK_BACK: WPARAM = 0x08;
pub const VK_TAB: WPARAM = 0x09;
pub const VK_RETURN: WPARAM = 0x0D;
pub const VK_SHIFT: WPARAM = 0x10;
pub const VK_CONTROL: WPARAM = 0x11;
pub const VK_MENU: WPARAM = 0x12;
pub const VK_CAPITAL: WPARAM = 0x14;
pub const VK_ESCAPE: WPARAM = 0x1B;
pub const VK_SPACE: WPARAM = 0x20;
pub const VK_PRIOR: WPARAM = 0x21;
pub const VK_NEXT: WPARAM = 0x22;
pub const VK_END: WPARAM = 0x23;
pub const VK_HOME: WPARAM = 0x24;
pub const VK_LEFT: WPARAM = 0x25;
pub const VK_UP: WPARAM = 0x26;
pub const VK_RIGHT: WPARAM = 0x27;
pub const VK_DOWN: WPARAM = 0x28;
pub const VK_INSERT: WPARAM = 0x2D;
pub const VK_DELETE: WPARAM = 0x2E;
pub const VK_LWIN: WPARAM = 0x5B;
pub const VK_RWIN: WPARAM = 0x5C;
pub const VK_NUMLOCK: WPARAM = 0x90;
pub const VK_LSHIFT: WPARAM = 0xA0;
pub const VK_RSHIFT: WPARAM = 0xA1;
pub const VK_LCONTROL: WPARAM = 0xA2;
pub const VK_RCONTROL: WPARAM = 0xA3;
pub const VK_LMENU: WPARAM = 0xA4;
pub const VK_RMENU: WPARAM = 0xA5;
pub const VK_OEM_1: WPARAM = 0xBA;
pub const VK_OEM_PLUS: WPARAM = 0xBB;
pub const VK_OEM_COMMA: WPARAM = 0xBC;
pub const VK_OEM_MINUS: WPARAM = 0xBD;
pub const VK_OEM_PERIOD: WPARAM = 0xBE;
pub const VK_OEM_2: WPARAM = 0xBF;
pub const VK_OEM_3: WPARAM = 0xC0;
pub const VK_OEM_4: WPARAM = 0xDB;
pub const VK_OEM_5: WPARAM = 0xDC;
pub const VK_OEM_6: WPARAM = 0xDD;
pub const VK_OEM_7: WPARAM = 0xDE;

// --- Funcoes utilizadas ---

pub extern "user32" fn RegisterClassExW(cls: *const WNDCLASSEXW) ATOM;
pub extern "user32" fn UnregisterClassW(name: LPCWSTR, instance: HINSTANCE) BOOL;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: LPCWSTR,
    window_name: LPCWSTR,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: HWND,
    menu: HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) LRESULT;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: HWND, min: UINT, max: UINT, remove: UINT) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) LRESULT;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: LPARAM) LPARAM;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) LPARAM;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: LPCWSTR) BOOL;
pub extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: HWND,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    flags: UINT,
) BOOL;
pub extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) BOOL;
pub extern "user32" fn IsZoomed(hwnd: HWND) BOOL;
pub extern "user32" fn SetFocus(hwnd: HWND) HWND;
pub extern "user32" fn SetCapture(hwnd: HWND) HWND;
pub extern "user32" fn ReleaseCapture() BOOL;
pub extern "user32" fn GetCapture() HWND;
/// Estado sincrono das teclas virtuais (SHORT). Bit 0x8000 = pressionada
/// no momento em que a mensagem atual foi retirada da fila.
pub extern "user32" fn GetKeyState(vk: c_int) i16;
pub extern "user32" fn EnumDisplayMonitors(
    hdc: HDC,
    clip: ?*const RECT,
    callback: MONITORENUMPROC,
    data: LPARAM,
) BOOL;
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) BOOL;
/// `EnumDisplaySettingsW` (wingdi.h): modos de um dispositivo de display.
/// `iModeNum` = `ENUM_CURRENT_SETTINGS` devolve o modo corrente.
pub extern "user32" fn EnumDisplaySettingsW(
    device: LPCWSTR,
    mode_index: DWORD,
    dev_mode: *DEVMODEW,
) BOOL;
/// `ChangeDisplaySettingsExW` (wingdi.h): aplica um modo de display.
/// `flags`/`visible` nulos e `param` nulo = troca dinamica (sem gravar no
/// registro).
pub extern "user32" fn ChangeDisplaySettingsExW(
    device: LPCWSTR,
    dev_mode: *const DEVMODEW,
    flags: ?[*:0]const u16,
    param: ?*anyopaque,
    visible: ?[*:0]const u16,
) LONG;

// --- Area de transferencia (clipboard) ---
pub extern "user32" fn OpenClipboard(hwnd: HWND) BOOL;
pub extern "user32" fn CloseClipboard() BOOL;
pub extern "user32" fn EmptyClipboard() BOOL;
pub extern "user32" fn SetClipboardData(format: UINT, data: ?*anyopaque) ?*anyopaque;
pub extern "user32" fn GetClipboardData(format: UINT) ?*anyopaque;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(mem: ?*anyopaque) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(mem: ?*anyopaque) BOOL;
pub extern "kernel32" fn GlobalFree(mem: ?*anyopaque) ?*anyopaque;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: DWORD) HMONITOR;
pub extern "user32" fn LoadCursorW(instance: HINSTANCE, name: usize) HCURSOR;
pub extern "user32" fn SetCursor(cursor: HCURSOR) HCURSOR;
pub extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) BOOL;
pub extern "user32" fn ClientToScreen(hwnd: HWND, pt: *POINT) BOOL;

pub extern "kernel32" fn GetModuleHandleW(name: LPCWSTR) HINSTANCE;

test "MINMAXINFO layout matches winuser.h" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(MINMAXINFO));
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(MINMAXINFO, "ptReserved"));
        try std.testing.expectEqual(@as(usize, 8), @offsetOf(MINMAXINFO, "ptMaxSize"));
        try std.testing.expectEqual(@as(usize, 24), @offsetOf(MINMAXINFO, "ptMinTrackSize"));
        try std.testing.expectEqual(@as(usize, 32), @offsetOf(MINMAXINFO, "ptMaxTrackSize"));
    }
}

test "DEVMODEW layout matches wingdi.h" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 220), @sizeOf(DEVMODEW));
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(DEVMODEW, "dmDeviceName"));
        try std.testing.expectEqual(@as(usize, 64), @offsetOf(DEVMODEW, "dmSpecVersion"));
        try std.testing.expectEqual(@as(usize, 66), @offsetOf(DEVMODEW, "dmDriverVersion"));
        try std.testing.expectEqual(@as(usize, 68), @offsetOf(DEVMODEW, "dmSize"));
        try std.testing.expectEqual(@as(usize, 70), @offsetOf(DEVMODEW, "dmDriverExtra"));
        try std.testing.expectEqual(@as(usize, 72), @offsetOf(DEVMODEW, "dmFields"));
        try std.testing.expectEqual(@as(usize, 76), @offsetOf(DEVMODEW, "dmPosition"));
        try std.testing.expectEqual(@as(usize, 84), @offsetOf(DEVMODEW, "dmDisplayOrientation"));
        try std.testing.expectEqual(@as(usize, 88), @offsetOf(DEVMODEW, "dmDisplayFixedOutput"));
        try std.testing.expectEqual(@as(usize, 92), @offsetOf(DEVMODEW, "dmColor"));
        try std.testing.expectEqual(@as(usize, 100), @offsetOf(DEVMODEW, "dmCollate"));
        try std.testing.expectEqual(@as(usize, 102), @offsetOf(DEVMODEW, "dmFormName"));
        try std.testing.expectEqual(@as(usize, 166), @offsetOf(DEVMODEW, "dmLogPixels"));
        try std.testing.expectEqual(@as(usize, 168), @offsetOf(DEVMODEW, "dmBitsPerPel"));
        try std.testing.expectEqual(@as(usize, 172), @offsetOf(DEVMODEW, "dmPelsWidth"));
        try std.testing.expectEqual(@as(usize, 176), @offsetOf(DEVMODEW, "dmPelsHeight"));
        try std.testing.expectEqual(@as(usize, 180), @offsetOf(DEVMODEW, "dmDisplayFlags"));
        try std.testing.expectEqual(@as(usize, 184), @offsetOf(DEVMODEW, "dmDisplayFrequency"));
        try std.testing.expectEqual(@as(usize, 216), @offsetOf(DEVMODEW, "dmPanningHeight"));
    }
}

test "MONITORINFOEXW layout matches winuser.h" {
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(usize, 104), @sizeOf(MONITORINFOEXW));
        try std.testing.expectEqual(@as(usize, 0), @offsetOf(MONITORINFOEXW, "cbSize"));
        try std.testing.expectEqual(@as(usize, 4), @offsetOf(MONITORINFOEXW, "rcMonitor"));
        try std.testing.expectEqual(@as(usize, 20), @offsetOf(MONITORINFOEXW, "rcWork"));
        try std.testing.expectEqual(@as(usize, 36), @offsetOf(MONITORINFOEXW, "dwFlags"));
        try std.testing.expectEqual(@as(usize, 40), @offsetOf(MONITORINFOEXW, "szDevice"));
    }
}
