// Zigway Win32: declaracoes manuais da ABI Win32 (sem @cImport).
//
// Convenções: x86_64-windows usa a mesma convencao de chamada que C para
// as APIs (a diferenca stdcall so importa em x86-32); callbacks usam
// `callconv(.winapi)`. Handles sao ponteiros opacos. Tamanhos conferidos
// para 64-bit: HANDLE=8, UINT=4, DWORD=4(u32), LONG=4(i32).

pub const HWND = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HDC = ?*anyopaque;

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

pub const SW_HIDE: c_int = 0;
pub const SW_SHOW: c_int = 5;

pub const PM_REMOVE: UINT = 0x0001;
pub const GWLP_USERDATA: c_int = -21;
pub const GWL_STYLE: c_int = -16;

pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;

pub const SIZE_MINIMIZED: WPARAM = 1;

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
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_SETCURSOR: UINT = 0x0020;
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
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) BOOL;
pub extern "user32" fn SetFocus(hwnd: HWND) HWND;
/// Estado sincrono das teclas virtuais (SHORT). Bit 0x8000 = pressionada
/// no momento em que a mensagem atual foi retirada da fila.
pub extern "user32" fn GetKeyState(vk: c_int) i16;
pub extern "user32" fn LoadCursorW(instance: HINSTANCE, name: usize) HCURSOR;
pub extern "user32" fn SetCursor(cursor: HCURSOR) HCURSOR;
pub extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD) BOOL;
pub extern "user32" fn ScreenToClient(hwnd: HWND, pt: *POINT) BOOL;

pub extern "kernel32" fn GetModuleHandleW(name: LPCWSTR) HINSTANCE;
