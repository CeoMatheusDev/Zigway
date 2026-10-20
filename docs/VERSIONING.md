# Versionamento — Zigway

SemVer 2.0.0: `MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`.

- Pré-1.0: série `0.x`; a API ainda pode quebrar entre minors.
- Pré-releases: `alpha` (experimental) → `beta` (testável) → `rc`
  (candidata) → estável. Nunca reutilizar número publicado nem mover tag.
- A versão canônica vive em `build.zig.zon` + `src/core/version.zig`
  (teste exige igualdade); cada release atualiza `CHANGELOG.md`.

## Estágios e critérios

| Versão | Critério de saída |
|---|---|
| v0.1.0-alpha.1 | fundação compila, testa e abre janelas |
| v0.1.0-alpha.2 | lifecycle + CI (esta) |
| v0.1.0-beta.1 | Win32 e X11 funcionais (Windows real validado) |
| v0.1.0-beta.2 | input e eventos completos |
| v0.1.0-rc.1 | testes/estabilização |
| v0.1.0 | primeira funcional |
| v0.2.0–v0.8.0 | Display/Cursor, texto/clipboard, gráficos, Wayland, gamepad, áudio, ABI C |
| v1.0.0 | API estável |

Releases `alpha/beta/rc` são publicadas como pré-release; estáveis como
release oficial, com changelog, plataformas, versão do Zig e resultados
de validação. Nenhuma publicação remota sem autorização explícita.
