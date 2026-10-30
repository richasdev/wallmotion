# Wallmotion agent instructions

Read and follow `/Users/uemuradev/.codex/RTK.md`. Prefix shell commands with `/opt/homebrew/bin/rtk`; use its `proxy` for unsupported commands.

## Product and implementation

- The product name is Wallmotion. Use descriptive component names such as DesktopCoordinator.
- Prioritize memory, energy, security, native rendering quality and accessibility.
- Use isolated worktrees for concurrent implementation. Never edit another agent's checkout.
- Compile Swift with `-j 2` during parallel work. Rust artifacts belong in `.build/native`; use `CARGO_INCREMENTAL=0` for checks.
- Clean generated artifacts between completed validation cycles with the project scripts; never clean global caches or another worktree.

## Mandatory PR and review workflow

These rules apply to every new change from 2026-10-30 onward, including documentation and maintenance.

### Two-Agent Protocol (User Override)

Per explicit user instruction, the project operates under a coordinated two-agent workflow:
- **rootCodex (Author):** Implements features, refactors, runtime and UI in isolated feature branches; creates draft PRs. The author never reviews or merges their own PR.
- **AGY (Reviewer & Merger):** Audits the exact PR HEAD SHA; publishes substantive findings, verification evidence, limitations and an explicit APPROVE or REQUEST_CHANGES verdict; verifies mergeability; marks PR ready and executes the merge guarded with `--match-head-commit <sha>`. Administrative overrides (`--admin`) and direct pushes to `main` are strictly forbidden.
- **Reciprocal Policy Reviews:** For policy or documentation PRs authored by AGY, rootCodex independently reviews and authorizes the exact HEAD SHA before AGY executes the merge.

1. Commit on a feature branch and open a draft PR. No direct pushes to main and no force pushes to shared branches.
2. The designated reviewer independently reviews the exact PR HEAD SHA. Every review includes bug hunting, correctness, security/memory and performance/visual quality as appropriate.
3. Reviewers must not be the author. The reviewer publishes findings, evidence, limits and an explicit APPROVE or REQUEST_CHANGES verdict tied to the HEAD SHA.
4. Every new commit invalidates earlier approvals. Resolve blocking findings and obtain fresh approval before merging that HEAD.
5. The designated merger agent verifies review records, current SHA, local checks, mergeability and any GitHub branch requirements. Only this agent marks the PR ready and merges it. Authors do not merge their own changes.
6. The merger records the reviewed SHA and evidence in the PR and guards the merge with `--match-head-commit`. Do not bypass branch protections or use administrative overrides.

All agents currently share the same GitHub account. Independent agent verdicts are NOT three distinct GitHub-account approvals; do not misrepresent them as such or claim GitHub branch protection enforces agent independence. See docs/REVIEW-POLICY.md.

GitHub Actions is blocked by account billing (issue #11). Record actual local checks and this remote limitation explicitly; never claim remote CI passed.
