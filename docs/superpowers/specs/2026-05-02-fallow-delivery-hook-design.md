# Fallow Delivery Hook (User-Scope)

**Data:** 2026-05-02
**Status:** Spec aprovado — pronto para writing-plans
**Autor:** brainstorming session com Claude Code
**Topic owner:** carielo@gmail.com

## 1. Objetivo

Garantir que toda "entrega de código" feita por Claude Code (uma sequência de tarefas que pode envolver subagentes em paralelo) seja submetida a um audit estático do **fallow** antes de fechar o turno, alimentando um ciclo de revisão rápido com feedback acionável. Habilitar isso no escopo de usuário (`~/.claude/`), de forma que valha para todos os projetos TS/JS automaticamente, sem fricção em projetos de outras linguagens nem risco de loops infinitos.

Sucesso = código permanece limpo "por construção" sem o usuário precisar lembrar de rodar `fallow` manualmente, e sem que o gate vire um obstáculo agressivo no fluxo.

## 2. Decisões já fechadas (Q1–Q5 do brainstorming)

| # | Decisão |
|---|---------|
| Q1 | Trigger = **Stop hook** + heurística de turno (só dispara se houve edit/write em arquivo TS/JS no último turno) |
| Q2 | Detecção de projeto = `package.json` em `$CLAUDE_PROJECT_DIR` **OU** `.fallowrc.{json,jsonc}` / `fallow.toml` na raiz (fallback explícito vence) |
| Q3 | Resposta por verdict = **híbrido**: `pass` silencioso, `warn` informa via stderr, `fail` bloqueia com feedback estruturado, **3-strike anti-loop** vira advisory "fala com user" |
| Q4 | Performance = síncrono com `FALLOW_HOOK_TIMEOUT=120` (default), `FALLOW_HOOK_MAX_DIFF=500` para skip de mass-refactor — nunca aborta trabalho do agente |
| Q5 | Distribuição = **degrade graceful** (PATH → npx → exit 0 silencioso) + bootstrap explícito via `fallow init --hook-user` |

## 3. Arquitetura

```
~/.claude/settings.json (Stop hook user-scope)
        │
        ▼
~/.claude/hooks/fallow-stop-gate.sh
        │
        ├─[1] stop_hook_active=true → exit 0
        │
        ├─[2] FALLOW_HOOK_DISABLED=1 → exit 0
        │
        ├─[3] Heurística de turno (jq sobre transcript_path)
        │     └─ zero edits TS/JS → exit 0
        │
        ├─[4] Detecção de projeto (package.json | .fallowrc | fallow.toml)
        │     └─ ausente → exit 0
        │
        ├─[5] Localização de binário (fallow → npx fallow → exit 0)
        │
        ├─[6] Validação de versão (FALLOW_HOOK_MIN_VERSION, default 2.61.0)
        │
        ├─[7] Skip por tamanho de diff (>FALLOW_HOOK_MAX_DIFF)
        │
        ├─[8] fallow audit --format json --quiet --explain (timeout 120s)
        │
        ├─[9] Carrega state file, calcula fail_count
        │
        └─[10] Decisão por verdict + count → exit code + JSON em stdout/stderr
```

Componentes:

| Item | Local | Responsabilidade |
|------|-------|------------------|
| `fallow-stop-gate.sh` | `~/.claude/hooks/` | Script principal, idempotente, fail-open |
| Settings entry | `~/.claude/settings.json` | Adiciona hook ao array `Stop[]`, coexiste com hooks pré-existentes |
| State file | `$CLAUDE_PROJECT_DIR/.claude/.fallow-hook-state.json` | Estado de loop por session_id, TTL 30min |
| `fallow init --hook-user` | binário fallow (nova flag em `crates/cli/src/init.rs`) | Bootstrap idempotente do hook |
| Log opcional | `~/.claude/.fallow-hook.log` | Append apenas quando `FALLOW_HOOK_DEBUG=1` ou `FALLOW_HOOK_DRY_RUN=1` |

## 4. Heurística de turno

Stop hook recebe input JSON em stdin com:

```json
{
  "session_id": "abc-123",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/path/to/project",
  "stop_hook_active": false
}
```

Processo:

1. Se `stop_hook_active == true` → exit 0 imediato. Claude Code já re-disparou Stop após nosso feedback anterior; nosso 3-strike trata o anti-loop, não precisamos re-rodar audit dentro da mesma iteração.
2. Lê `transcript_path` (JSONL) com `tail -n 500` para limitar custo de I/O em transcripts longos.
3. Filtro jq:
   ```
   jq -r 'select(.type=="assistant")
          | .message.content[]?
          | select(.type=="tool_use")
          | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
          | .input.file_path // empty'
   ```
4. Match regex (case-insensitive): `\.(ts|tsx|js|jsx|mjs|cjs|mts|cts|svelte|vue|astro)$`
5. Exclui paths sob `node_modules/`, `.git/`, `dist/`, `build/`, `target/`, `.next/`, `.nuxt/`.
6. Se zero matches → exit 0 silencioso (ou stderr nota se `FALLOW_HOOK_DEBUG=1`).
7. ≥1 match → segue para detecção de projeto.

## 5. Detecção de projeto TS/JS

Em `$CLAUDE_PROJECT_DIR` (ou `cwd` do hook input se ausente):

```
1. .fallowrc.json | .fallowrc.jsonc | fallow.toml | .fallow.toml exists? → roda
2. package.json exists? → roda
3. nada acima? → exit 0 silencioso
```

`.fallowrc` campo `hook.disabled = true` é honrado: hook lê o JSON, exit 0 se desativado por projeto.

## 6. Estado de loop (3-strike)

Arquivo: `$CLAUDE_PROJECT_DIR/.claude/.fallow-hook-state.json` (mode 600).

Schema:

```json
{
  "session_id": "abc-123",
  "fail_count": 2,
  "last_verdict": "fail",
  "last_ts": 1714579200,
  "last_fingerprint": "sha1-of-sorted-paths-and-codes",
  "advisory_locked": false
}
```

Regras:

| Evento | Mutação |
|--------|---------|
| Verdict `pass` ou `warn` | `fail_count = 0`, `advisory_locked = false`, atualiza `last_verdict`/`last_ts` |
| `fail` E (`session_id` mudou OU `last_ts` > 30min ago) | `fail_count = 1` (reset por sessão/TTL) |
| `fail` E sessão atual E ts recente | `fail_count++` |
| `fail_count >= 3` | `advisory_locked = true` — advisory mode até `pass`/`warn` reset |
| Skip/timeout/erro | NÃO mexe no estado (fail-open) |

Persistência atômica: `mktemp + mv`. Sem `flock` — Stop hooks são serializados por sessão pelo Claude Code.

`advisory_locked = true` permanece até `pass`/`warn` aparecer ou TTL expirar. Evita re-loop após user instruir Claude a continuar.

`last_fingerprint` = SHA1 sobre `sort(unique(path:line:rule_code))` dos findings introduced. Usado para log/debug, **não** participa da decisão de bloqueio (3-strike é puro count). Roadmap: futuro fingerprint-aware mode (se mesmo fingerprint 2x seguidas, escala para advisory imediato sem esperar 3).

## 7. Contrato de saída

### 7.1 `pass`

```
exit 0
stdout: vazio
stderr: vazio (ou debug breve se DEBUG)
state: fail_count=0
```

### 7.2 `warn`

```
exit 0
stdout: vazio
stderr: ⚠ fallow audit: N warn findings — considere /review antes de fechar entrega
state: fail_count=0
```

User vê no terminal; Claude não age automaticamente. Filosofia: warn é informativo, não interruptivo.

### 7.3 `fail` com `fail_count < 3`

```
exit 0  (porque usamos JSON com decision:block; exit 0 sinaliza JSON output válido)
stdout (JSON):
{
  "decision": "block",
  "reason": "<resumo_filtrado>"
}
state: fail_count++
```

`<resumo_filtrado>` é texto curto, formato:

```
fallow audit verdict=fail (tentativa N de 3 antes de bloquear consultoria)
changed_files=M — introduced this turn:
  dead_code: X (Y unused-export, Z unused-deps)
  complexity: P (max cyclomatic=…)
  duplication: Q

Top issues introduced:
  • src/utils.ts:42 unused-export `helper` [actions: remove-export (auto-fixable)]
  • src/foo.ts:5 cyclomatic=18 cognitive=30 [actions: refactor-function]
  …até 10 issues, depois "+K more"

Full details + actions: re-run `fallow audit --explain --format json` locally.
```

Cap de 10 issues, footer `+K more` se houver mais. Tamanho alvo do `reason`: ≤2 KB. Foco em `introduced: true` apenas (gate=new-only é o default do audit).

### 7.4 `fail` com `fail_count >= 3`

```
exit 0
stdout (JSON):
{
  "decision": "block",
  "reason": "<advisory_stop>"
}
state: advisory_locked=true (mantém até pass/warn ou TTL)
```

`<advisory_stop>`:

```
🛑 fallow audit falhou 3× consecutivas no mesmo session.

Verdict atual: fail (introduced=N).
Estagnação detectada — pare de tentar corrigir.

INSTRUÇÃO PARA CLAUDE: NÃO tente outro fix. Apresente os findings ao
usuário, explique tentativas até agora, peça orientação antes de
continuar editando código.

Last fingerprint: <hash>
Reset automático em: novo `pass`/`warn` no audit, OU 30min idle, OU
sessão Claude nova.
```

A intenção é forçar Claude a perguntar ao user via texto explícito no `reason`. Modelos seguem a instrução de "pare e pergunte".

### 7.5 Skip / timeout / erro de runtime

Todos terminam em:

```
exit 0
stdout: vazio
stderr: fallow-stop-gate: <motivo curto>, skipping audit.
state: inalterado
```

Motivos esperados: `jq não instalado`, `transcript não legível`, `binário não encontrado`, `versão abaixo do floor`, `audit timeout após Ns`, `diff > N arquivos`, `audit retornou exit 2 sem JSON parseável`, `network error 7`.

Filosofia: fail-open. Hook nunca pode quebrar o fluxo do usuário por bug próprio. Stderr fica visível.

## 8. Bootstrap: `fallow init --hook-user`

Nova flag no comando existente `fallow init` (`crates/cli/src/init.rs`).

### 8.1 Comportamento

```
$ fallow init --hook-user
Detecting Claude Code config…
✓ Found ~/.claude/settings.json (existing hooks preserved)
✓ Created ~/.claude/hooks/fallow-stop-gate.sh (mode 755)
✓ Updated ~/.claude/settings.json: Stop[] += fallow-stop-gate
ℹ Backup saved to ~/.claude/settings.json.bak.20260502T143022

Coexists with: hookz speaker (Stop), 1 other hook(s)

Binary: not found on PATH
  npm install -g fallow            # recommended
  cargo install fallow-cli         # alternative
  Hook fails-open if binary missing — install when ready.

Next steps:
  1. Install fallow binary (above)
  2. Test with FALLOW_HOOK_DEBUG=1 in a Claude session inside a TS/JS repo
  3. (recommended) Run with FALLOW_HOOK_DRY_RUN=1 for ~1 week before live mode
  4. Uninstall: fallow init --hook-user --uninstall
```

### 8.2 Idempotência

Re-rodar `fallow init --hook-user` **não duplica entries** — dedupe por substring no campo `command` (procura `fallow-stop-gate.sh`). Se já presente, pula com mensagem `already installed`. Atualiza apenas o script.

### 8.3 Uninstall

```
$ fallow init --hook-user --uninstall
✓ Removed Stop[] entry pointing to fallow-stop-gate.sh from ~/.claude/settings.json
✓ Removed ~/.claude/hooks/fallow-stop-gate.sh
ℹ State files in <project>/.claude/.fallow-hook-state.json kept (manual remove if desired)
```

### 8.4 Implementação

- Script `fallow-stop-gate.sh` embedded via `include_str!` em `crates/cli/src/setup_hooks/fallow-stop-gate.sh`.
- Settings.json manipulation: `serde_json::Value` + path navigation; backup antes de gravar.
- Path resolution: `dirs::home_dir()` para portabilidade. Em Windows, igual `fallow-gate.sh`, requer git-bash/WSL para o `.sh` rodar — Claude Code roda hooks via shell.

## 9. Coexistência

| Camada | Escopo | Trigger | Quando atua |
|--------|--------|---------|-------------|
| User Stop gate (este spec) | `~/.claude/` | Stop hook | A cada turno; soft, loop-aware |
| Project commit gate (`fallow setup-hooks`, existente) | `<repo>/.claude/` | PreToolUse Bash `git commit/push` | Antes de commit/push; hard block |
| Outros Stop hooks (hookz speaker, etc.) | qualquer | Stop hook | Independente — coexistem no array |

Stop array é serial. Ordem: hookz speaker primeiro (existente), fallow-stop-gate por último (novo). Tempo total ≤60s no pior caso (timeout default Claude Code), com nosso `FALLOW_HOOK_TIMEOUT=120` cobrindo audit isolado.

## 10. Configuração

### 10.1 Variáveis de ambiente

| Var | Default | Função |
|-----|---------|--------|
| `FALLOW_HOOK_DISABLED` | unset | `1` = exit 0 imediato |
| `FALLOW_HOOK_DRY_RUN` | unset | Calcula verdict mas exit 0 sempre + log |
| `FALLOW_HOOK_DEBUG` | unset | Log verbose em stderr (decisões, paths, timings) |
| `FALLOW_HOOK_TIMEOUT` | 120 | Segundos para `fallow audit` |
| `FALLOW_HOOK_MAX_DIFF` | 500 | Skip se `git diff --name-only` >N arquivos |
| `FALLOW_HOOK_LOOP_LIMIT` | 3 | Strikes para virar advisory |
| `FALLOW_HOOK_LOOP_TTL_SECS` | 1800 | Reset count após N segundos idle |
| `FALLOW_HOOK_MIN_VERSION` | 2.61.0 | Floor de versão do binário |
| `FALLOW_HOOK_STATE_DIR` | `$CLAUDE_PROJECT_DIR/.claude` | Override local do state file |
| `FALLOW_HOOK_LOG` | `~/.claude/.fallow-hook.log` | Caminho do log (DEBUG/DRY_RUN) |

### 10.2 Configuração por projeto

`.fallowrc.json`:

```json
{
  "hook": {
    "disabled": false,
    "timeout": 120,
    "max_diff": 500,
    "loop_limit": 3
  }
}
```

Precedência (high → low): env var > `.fallowrc` > default.

## 11. Rollout em 2 fases

### Fase 1 — Dry-run (1 semana)

- Instala via `fallow init --hook-user`
- User exporta `FALLOW_HOOK_DRY_RUN=1` no shell que sobe Claude Code (ex: `~/.zshrc`)
- Hook calcula tudo (heurística, audit, decisão), mas NUNCA bloqueia
- Tudo é logado em `~/.claude/.fallow-hook.log` (timestamp, projeto, verdict, count, motivo de skip)
- Critério de saída: ≥1 semana sem falsos positivos chatos confirmados pelo user via review do log

### Fase 2 — Live

- Remove `FALLOW_HOOK_DRY_RUN` do shell
- Block + advisory ativos
- Continue monitorando log se `FALLOW_HOOK_DEBUG=1`

## 12. Estratégia de testes

### 12.1 Unit (bash + bats-style)

Em `crates/cli/tests/fallow-stop-gate/`:

- Mock binário `fallow` via `tests/mocks/fallow` (script bash que retorna JSON canned)
- Test cases:
  - `pass` → exit 0, sem stdout
  - `warn` → exit 0, stderr com nota
  - `fail` count<3 → exit 0, stdout JSON com `decision:block`, reason filtrado <2KB
  - `fail` count==3 → exit 0, stdout JSON com advisory_stop reason
  - Sequência fail→fail→fail→fail = 3 blocks normais + 1 advisory
  - `pass` reseta count
  - Sessão nova reseta count
  - TTL expirado reseta count
  - Heurística: zero edits TS/JS → exit 0 imediato
  - Heurística: edit em `.ts` mas sob `node_modules/` → exit 0
  - `package.json` ausente → exit 0
  - `.fallowrc.json` com `hook.disabled=true` → exit 0
  - Diff >500 arquivos → skip com stderr nota
  - `FALLOW_HOOK_DISABLED=1` → exit 0
  - Binário ausente → exit 0 silencioso
  - Versão abaixo do floor → exit 2 com mensagem (igual fallow-gate)
  - Timeout → fail-open
  - `stop_hook_active=true` → exit 0
  - JSON malformado de `fallow audit` → fail-open
  - State file corrupto → reseta state e segue
  - Concorrência de escrita: state file íntegro após SIGTERM

### 12.2 Rust (init crate)

- `init --hook-user` em settings.json vazio → cria estrutura completa
- `init --hook-user` em settings.json com hookz speaker existente → preserva, adiciona próprio
- `init --hook-user --uninstall` → remove só nosso entry
- Re-run idempotente
- Backup criado antes de gravar
- JSON inválido em settings.json → aborta com erro claro

### 12.3 Smoke E2E manual

Script `scripts/test-stop-hook.sh`:

1. Cria fixture TS/JS temporária
2. Constrói transcript JSONL com Edit fake em `.ts`
3. Roda `fallow-stop-gate.sh` com input simulando Stop hook
4. Asserta saída por verdict

## 13. Segurança

- Sem `eval` ou interpolação direta de strings em comandos: tudo via array `${RUNNER[@]}`, igual `fallow-gate.sh`
- jq queries: `--arg` para inputs externos; nunca shell-out de `file_path`
- State file: mode 600, escrita atômica via `mktemp + mv`
- Settings.json: backup antes de cada modificação, validação JSON antes de overwrite
- Validação de versão: regex `^fallow [0-9]+\.[0-9]+\.[0-9]+`
- Path traversal: state dir é `$CLAUDE_PROJECT_DIR/.claude/` (não aceita override de path absoluto sem validação)
- Advisory reason text: gerado server-side pelo nosso script, não inclui input bruto do user em campo controlado por Claude

## 14. Decisões deliberadamente excluídas (YAGNI)

- **Não auto-spawnar agente reviewer**: custo de tokens não justifica. Sugestão textual basta — Claude decide se chama `/review`.
- **Não fingerprint-aware loop detection** no MVP: 3-strike puro é suficiente. Roadmap se virar problema.
- **Não hot-reload de config**: hook lê env+config a cada execução, sem daemon. Re-exec é barato.
- **Não suporte a múltiplos repos no mesmo turno**: assume `cwd`/`CLAUDE_PROJECT_DIR` é o repo alvo. Edits cruzados em workspaces nested → audit roda no repo identificado, não tenta ser esperto.
- **Não integração direta com `/superpowers:requesting-code-review`**: warn sugere via texto, sem invocar skill via hook.

## 15. Riscos abertos

| Risco | Mitigação |
|-------|-----------|
| Falsos positivos em monorepo onde `package.json` raiz é só workspace shell | Detecção de projeto secundária via `.fallowrc.json`; user pode opt-out por repo |
| Edits via `Bash(sed/cat>)` não são detectados pela heurística | Aceito — heurística é best-effort; falsos negativos ocasionais melhor que rodar audit em projeto Rust |
| Audit pode demorar em repo cold-cache 1ª vez | Timeout 120s + skip por diff >500; user pode rodar `fallow check` manual antes para warm cache |
| `transcript_path` formato pode mudar entre versões Claude Code | Heurística degrada graciosamente em parse error → trata como "edits possíveis", roda audit |
| Hookz speaker timeout ≥60s com Stop array bloqueia turno | Documentar: Stop array é serial; manter hookz speaker rápido |

## 16. Critérios de aceitação

- [ ] `fallow init --hook-user` instala/desinstala idempotente, preservando hooks pré-existentes
- [ ] Script `fallow-stop-gate.sh` passa em todos os casos da seção 12.1
- [ ] Em projeto não-TS/JS, hook custa <50ms (heurística + detecção, exit 0)
- [ ] Em projeto TS/JS sem mudanças TS/JS no turno, hook custa <100ms (heurística → exit 0)
- [ ] `verdict=fail` com 1 issue introduced gera `reason` ≤2KB com action sugerida
- [ ] 3 falhas consecutivas → 3º vira advisory; `pass` reseta para 0
- [ ] `FALLOW_HOOK_DRY_RUN=1` nunca emite `decision:block`
- [ ] Binário ausente → exit 0 silencioso (não interrompe user)
- [ ] State file corrompido → reseta sem crashar
- [ ] Documentação em `docs/` cobrindo: instalação, troubleshooting, escape hatches, env vars

## 17. Próximos passos

1. **Plano de implementação** via skill `superpowers:writing-plans` (próximo passo após user aprovar este spec)
2. Implementação iterativa por componente: script → init flag → state machine → reason builder → testes
3. Release no próximo `chore: release` ciclo do fallow
4. Onboarding de usuários via `npm/fallow/skills/` skill update + README

## Referências

- Comando existente `fallow audit`: `crates/cli/src/audit.rs`
- Project gate existente (PreToolUse commit): `crates/cli/src/setup_hooks/fallow-gate.sh`, `crates/cli/src/setup_hooks/settings.json`
- Init existente: `crates/cli/src/init.rs`
- Hooks docs (Claude Code): `~/.claude/` settings schema, `transcript_path` JSONL format
- ADRs relacionados: nenhum direto; este spec é independente
