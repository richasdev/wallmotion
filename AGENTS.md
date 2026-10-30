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

1. Commit on a feature branch and open a draft PR. No direct pushes to main and no force pushes to shared branches.
2. At least three distinct agent sessions must independently review the exact PR HEAD SHA. Every review includes bug hunting; cover correctness, security/memory and performance/visual quality as appropriate.
3. Reviewers must not be the author or merger. Each publishes findings, evidence, limits and an explicit APPROVE or REQUEST_CHANGES verdict tied to the HEAD SHA and its own runtime/session identity.
4. Every new commit invalidates earlier approvals. Resolve blocking findings and obtain three fresh approvals before merging that HEAD.
5. A separate designated merger agent verifies the three review records, current SHA, local checks, mergeability and any GitHub branch requirements. Only this agent marks the PR ready and merges it. Authors, reviewers and the coordinator do not merge their own changes.
6. The merger records the reviewed SHA and evidence in the PR and guards the merge with `--match-head-commit`. Do not bypass branch protections or use administrative overrides.

All agents currently share the same GitHub account. Independent agent verdicts are NOT three distinct GitHub-account approvals; do not misrepresent them as such or claim GitHub branch protection enforces agent independence. See docs/REVIEW-POLICY.md.

GitHub Actions is blocked by account billing (issue #11). Record actual local checks and this remote limitation explicitly; never claim remote CI passed.
