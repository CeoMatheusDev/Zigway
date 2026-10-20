// Zigway Core: conjunto de erros da API.
//
// As funcoes publicas usam error sets inferidos (`!T`); este arquivo
// documenta os erros especificos que o Zigway pode retornar, alem de
// `error.OutOfMemory` do alocador.

pub const Error = error{
    /// Backend solicitado nao existe para o alvo compilado
    /// (ex.: .win32 em Linux, .x11 em Windows).
    UnsupportedBackend,
    /// Backend reconhecido mas ainda nao implementado (ex.: Wayland).
    NotImplemented,
    /// Nenhum display/dispositivo de janelas disponivel
    /// (ex.: XOpenDisplay falhou).
    NoDisplay,
    /// Falha ao conectar/negociar com o sistema de janelas.
    ConnectionFailed,
    /// Operacao sobre plataforma ja encerrada (`deinit` executado).
    PlatformClosed,
    /// Configuracao de janela invalida (dimensoes, titulo, capacidade).
    InvalidConfig,
    /// Falha na criacao da janela nativa.
    WindowCreationFailed,
    /// Falha ao criar ou aplicar um cursor do sistema.
    CursorCreationFailed,
    /// Falha ao capturar o ponteiro (janela nao visivel, grab negado ou
    /// captura detida por outra thread/cliente).
    PointerCaptureFailed,
    /// WindowId invalido, expirado ou de outra instancia.
    InvalidWindow,
};
