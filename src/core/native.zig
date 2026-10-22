// Zigway Core: handles nativos de janela.
//
// Permitem integrar APIs graficas externas (EGL/OpenGL, Vulkan, ...) sem
// que o Zigway implemente um renderer. Somente `std`; sem estado global.
//
// Ownership: os handles sao emprestados. Valem enquanto a janela e a
// `Platform` que os originaram existirem; nunca fechar/destruir o
// `Display` ou a janela por fora do Zigway.

/// Handle nativo de uma janela, por backend.
///
/// Hoje so o backend X11 o fornece; os demais backends retornam
/// `error.NotImplemented` em `Window.nativeHandle()`.
pub const NativeHandle = union(enum) {
    /// Xlib: `Display*` + XID da janela.
    x11: X11,

    pub const X11 = struct {
        /// `Display*` da conexao Xlib da `Platform` (opaco).
        display: *anyopaque,
        /// XID (`Window`) da janela.
        window: c_ulong,
        /// `VisualID` da janela (visual padrao da tela). Necessario para
        /// escolher uma configuracao de superficie compativel (ex.: EGL).
        visual_id: c_ulong,
    };
};
