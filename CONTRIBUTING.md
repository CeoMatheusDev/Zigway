# Contributing — Zigway

## Como contribuir

1. Abra uma issue descrevendo o problema ou a proposta antes de
   mudanças grandes (API, backends, lifecycle).
2. Crie um branch a partir de `main`: `feat/...`, `fix/...`,
   `docs/...`, `test/...`, `ci/...`, `chore/...`.
3. Trabalhe incrementalmente sobre o código existente; não recrie
   módulos funcionais nem mova arquivos sem necessidade.
4. Atualize `CHANGELOG.md` em `## [Não lançado]` (toda mudança).
5. Abra o PR com o template preenchido.

## Antes de enviar

```bash
zig build
zig build test
zig build test-x11   # se houver display; pula sem ele
zig fmt --check .
```

Para mudanças no backend Win32, valide também a compilação cruzada:

```bash
zig build -Dtarget=x86_64-windows -Dplatform=win32
```

## Padrão de commits

Conventional Commits, pequenos e organizados:

```text
feat(x11): map additional keysyms
fix(events): preserve close on queue overflow
test(platform): cover allocation failure
docs: update backend limitations
ci: add Xvfb live test job
chore: rename docs to uppercase
```

Um commit = uma preocupação. Sem `push --force`, sem reescrever
histórico publicado.

## Requisitos para aprovação

- Build + testes verdes; `zig fmt --check` limpo.
- Sem dependências externas, sem `@cImport`, sem APIs fora do Zig 0.17.0.
- API pública preservada ou breaking change documentada no CHANGELOG.
- Docs atualizadas para refletir o estado real do código.
- Sem funcionalidade fictícia; sem teste declarado sem execução.

## Aprovação e releases

Revisão do mantenedor. Commit não é release: tags `vX.Y.Z` e GitHub
Releases são criadas pelo mantenedor após validação completa.
