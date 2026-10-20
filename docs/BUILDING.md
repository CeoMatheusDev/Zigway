# Building — Zigway

## Requisitos

- Zig **0.17.0** (`zig version` deve imprimir `0.17.0`).
- Linux/X11: headers + lib de desenvolvimento:
  - Fedora: `sudo dnf install libX11-devel`
  - Debian/Ubuntu: `sudo apt install libx11-dev`
  - Opcional em runtime (sem impacto no build): `libXrandr.so.2`
    (RandR 1.5+) para enumeração de monitores físicos; sem ela,
    `Platform.displays` cai para X screens.
- Windows: SDK padrão (nada extra além do Zig).

## Comandos

```bash
zig build              # compila a biblioteca estática
zig build test         # testes unitários (headless; backend null)
zig build test-x11     # integração X11 (display real; pula sem display)
zig build examples     # hello_window, multiple_windows, keyboard_input, displays
zig fmt --check .      # formatação (a CI exige limpo)
```

Saídas em `zig-out/` (`bin/`, `lib/`); cache em `.zig-cache/`
(ambos ignorados pelo git).

## Seleção de backend

`-Dplatform` define o padrão usado quando
`Platform.Options.backend == .auto`:

| Opção | Efeito |
|---|---|
| `auto` (padrão) | SO decide (Linux→X11, Windows→Win32, demais→null) |
| `x11` | exige alvo Linux (senão o build falha) |
| `win32` | exige alvo Windows (senão o build falha) |
| `null_backend` | headless; útil em CI sem display |
| `wayland` | **rejeitado no build** (não implementado) |

Em runtime, `Options.backend` pode fixar `.x11`, `.win32` ou
`.null_backend`; `.wayland` retorna `error.NotImplemented` e backend
de outro SO retorna `error.UnsupportedBackend`.

## Compilação cruzada

```bash
# Win32 a partir do Linux (valida o backend Win32 sem Windows)
zig build -Dtarget=x86_64-windows -Dplatform=win32
```

Compilação cruzada **não** é validação de runtime: o backend Win32
só se considera validado em Windows real (pendente).

## Testes com display no CI

`zig build test-x11` precisa de servidor X. Sem `DISPLAY`, o teste
pula graciosamente (não falha). No CI Linux, usar Xvfb:

```bash
sudo apt install xvfb libx11-dev
xvfb-run -a zig build test-x11
```

## Solução de erros

| Sintoma | Causa provável |
|---|---|
| `error.NoDisplay` | sem servidor X / `DISPLAY` ausente → use `.null_backend` |
| `error.UnsupportedBackend` | `.win32` em Linux ou `.x11` em Windows |
| `error.InvalidConfig` | dimensão 0, título > 1024 bytes, capacidade 0 |
| `error.InvalidWindow` | id expirado ou de outra instância |
| `ld: cannot find -lX11` | falta `libX11-devel`/`libx11-dev` |
| `panic` com `-Dplatform=wayland` | esperado: não implementado |
| `expected -Dplatform to be ...` | valor inválido (ex.: `null` em vez de `null_backend`) |

## Primeiro programa

Ver exemplo completo no `README.md` (seção Exemplo) e em
`examples/hello_window.zig`.
