# PR review policy

Every change goes through a PR, independent agent review and a non-author merger. The latest explicit user instruction on 2026-11-08 requests multiple Codex agents, one AGY and one Claude Code. This supersedes the earlier two-agent count. This policy applies to documentation and maintenance as well as code.

## Multi-agent workflow (User Override · 2026-11-08)

1. **Codex implementers (Authors):** Authors of runtime, state, UI, branding and core changes. Works in isolated branches, opens draft PRs, and requests review. The author never merges their own PR.
2. **Codex and Claude Code (Independent Reviewers):** Review PRs they did not author. Require at least three substantive non-author exact-HEAD reviews. Every new commit invalidates all earlier verdicts.
3. **AGY (Reviewer & Merger):** Conducts thorough, independent read-only review of the exact HEAD SHA; publishes substantive findings, local verification checks, limitations and explicit APPROVE or REQUEST_CHANGES verdict. Upon approval, verifies mergeability, marks the PR ready, and merges guarded with `--match-head-commit <sha>`. Administrative overrides (`--admin`) are prohibited.
4. **Exceção de Policy/Docs:** Para PRs de governança/docs de autoria de AGY, o `rootCodex` atua como revisor independente no SHA exato. Somente após a aprovação explícita do rootCodex no SHA exato, AGY executa o merge com `--match-head-commit`.
5. **Takeover de Emergência (Autorizado pelo Usuário):** Se AGY parar de responder ou sua quota estiver indisponível, o `rootCodex` está expressamente autorizado pelo usuário a assumir o ciclo (criação de issues, revisão e merge). O root audita o PR, HEAD SHA e checagens locais reais sem fingir aprovação independente de contas, executando o merge guardado com `--match-head-commit` e sem `--admin`, limitado ao teto semanal de 60% da quota do Codex.

## Evidence

The reviewer posts a substantive PR comment with findings first, tests or inspection performed, limitations, stable reviewer ID, live terminal/session identity and the exact full HEAD SHA. Include this machine-readable record after the human-readable review:

```text
<!-- wallmotion-agent-review {"reviewer_id":"AGY","session_id":"terminal_session_identifier","head_sha":"full_40_character_sha","verdict":"APPROVE"} -->
```

Use REQUEST_CHANGES if blocking issues remain. Approval requires actual independent inspection; never approve merely because the author requested it. Optional improvements must be distinguished from bugs.

A new commit invalidates all prior approvals, even if it appears small. The merger must confirm matching SHA, absence of unresolved blocking findings and local validation evidence before executing the merge.

## Merger

The merger must not be the author of the code PR under review. Autores nunca mergeiam suas próprias alterações de código. Exceção explícita aplica-se exclusivamente a PRs de policy/documentação de autoria de AGY após aprovação formal do rootCodex no SHA exato. O merger verifica os metadados do PR e comentários antes de agir, checa conflitos e requisitos de branch, e mergeia apenas o HEAD aprovado usando `gh pr merge --match-head-commit <sha>`. Não é permitido modificar código para resolver conflitos nem utilizar sobreposições administrativas (`--admin`) ou pushes diretos no `main`.

## Limitação de Conta GitHub

Todos os agentes compartilham a mesma conta GitHub autenticada (`richasdev`). Pareceres de agentes não são aprovações de contas GitHub independentes e não satisfazem nativamente branch protection por múltiplas contas. Verificações reais locais e limitações externas (como a cobrança no issue #11) devem ser relatadas explicitamente.

## GitHub account limitation

These agents use the same authenticated GitHub account, richasdev. GitHub does not permit this account to approve its own PR as three distinct reviewers. Therefore, agent decisions are published as PR comments and enforced through the coordination workflow. They are not formal GitHub review approvals and do not provide independent-account authorization. Requiring three native GitHub approvals would require distinct authorized reviewer accounts or an explicitly configured app identity setup.

## Validation

Use the local checks appropriate to each change and record their exact commands and results. On 2026-11-08 the user explicitly ordered GitHub Actions stopped; repository Actions and the macOS checks workflow are disabled. Do not trigger, rerun, dispatch or re-enable Actions without a new explicit user instruction. Issue #11 records the earlier billing limitation. No remote CI success is claimed. Any configured GitHub required check or branch protection still applies and must not be bypassed.
