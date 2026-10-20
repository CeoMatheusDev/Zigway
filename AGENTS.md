# Zigway — instruções persistentes

Native platform backend em **Zig 0.17.0**: janelas, eventos e input
sobre Win32/X11/null, API Zig nativa, sem `@cImport`, sem dependências
externas. Versão atual: **0.1.0-alpha.4**. Repositório (pendente de
criação): https://github.com/CeoMatheusDev/Zigway

## Regras absolutas

- Zig 0.17.0 somente. Nunca presumir APIs: conferir em
  `/home/matheus/.local/opt/zig/0.17.0/lib/std/` antes de usar.
  Incompatibilidades conhecidas com versões antigas: `std.ArrayList`
  é unmanaged (alocador por chamada), `@typeInfo(...).@"enum"` usa
  `field_names`, sem `std.os.argv`, sem `Allocator.dupeZ`, link via
  `Module.linkSystemLibrary`.
- **Nunca** `@cImport`, headers C, ou pacotes externos. ABIs nativas
  declaradas manualmente (`src/platform/<backend>/api.zig`).
- Preservar API pública Zig, multi-janelas, handles geracionais,
  alocador explícito, error sets, sem estado global.
- ABI C é camada opcional futura e isolada — nunca remodelar o núcleo
  para ela nesta fase.
- Separação Platform Backend vs. RHI: Zigway integra a janela à API
  gráfica; nunca implementar renderer, dispositivo ou pipeline aqui.
- Nunca implementar funcionalidade fictícia nem anunciar backend como
  disponível sem validação (Wayland é o caso atual).
- Nunca afirmar teste/build aprovado sem executar. Repositório sem
  remoto publicado: nada de push/tag/release sem autorização explícita.

## Fluxo por tarefa

1. Analisar: objetivo, arquivos relevantes, contratos, risco de regressão.
2. Implementar pequeno e verificável, só arquivos da tarefa.
3. Validar de verdade antes de prosseguir:
   - `zig build`
   - `zig build test`
   - `zig build test-x11` (pula sem display; com display, valida)
   - `zig fmt --check .`
   - cross Windows quando tocar Win32: `zig build -Dtarget=x86_64-windows -Dplatform=win32`
   - Investigar falhas; corrigir; revalidar.
4. Revisar o diff (`git status`, stage seletivo); sem segredos.
5. Commit pequeno (Conventional Commits). Push/tag/release SOMENTE
   com autorização explícita.
6. Relatar: feito, validado (comandos + resultados), commit, impacto
   SemVer, pendências. Diferenciar implementado / testado / compilado /
   não testado / planejado / bloqueado.

## Módulos (não mover sem atualizar imports + build)

- `src/core/` — version, errors, types, handles, caps (só `std`).
- `src/events.zig`, `src/input.zig` — só `core`.
- `src/platform/registry.zig` — slots geracionais (sem `Platform`).
- `src/platform/{null_backend,x11/,win32/}` — nunca importam `platform`.
- `src/platform/platform.zig` — dono de tudo; despacho por `inline else`.
- `src/window.zig` — handle `{id, *Platform}`; único par com import
  mútuo (só o tipo `*Platform`).
- `tests/live_x11.zig` — integração com display real; pular (não falhar)
  sem backend disponível.

## Tratamento de erros e ownership

- Erros específicos em `core/errors.zig` + `OutOfMemory`; funções
  públicas usam error sets inferidos.
- `Platform` detém fila, input, registro e backend. `Window.deinit()`
  é infalível (para `defer`); inválido é ignorado.
- Falha parcial sempre desfaz o adquirido (`errdefer`).
- `windowShouldClose` com id inválido retorna `true` (falha segura).

## Testes e docs

- Unitários headless no backend null; nada que exija display em
  `zig build test`. Teste live separado e tolerante.
- Versão canônica em `build.zig.zon` + `src/core/version.zig`, com
  teste de sincronia (não mexer sem atualizar os dois + CHANGELOG).
- Documentar só o estado real; limitações em `docs/BACKENDS.md`.

## Git e releases (SemVer 2.0.0)

- Proibido sem autorização: `push --force`, `reset --hard`, `clean -fd`,
  reescrever histórico, mover/excluir tags, publicar remoto.
- Commit + push NÃO é release. Mudanças entram em `## [Não lançado]`.
- Tag `vX.Y.Z` (anotada) só com validação completa + changelog correto;
  pré-releases marcadas como pre-release no GitHub.

## Segurança

- Validar tamanhos, handles, strings e limites antes de chamadas nativas.
- Nunca logar ou commitar segredos; reportar vulnerabilidades conforme
  `SECURITY.md`.
