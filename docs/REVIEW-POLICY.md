# PR review policy

Every change goes through a PR, independent agent review and a non-author merger. Per explicit user override on 2026-10-30, operations are streamlined to a two-agent structure (`rootCodex` as author, `AGY` as reviewer and merger) to maintain velocity while strictly preserving separation of duties and review rigor. This policy applies to documentation and maintenance as well as code.

## Two-agent workflow (User Override)

1. **rootCodex (Author):** Author of runtime, state, UI and core changes. Works in isolated branches, opens draft PRs, and requests review. The author never merges their own PR.
2. **AGY (Reviewer & Merger):** Conducts thorough, independent read-only review of the exact HEAD SHA; publishes substantive findings, local verification checks, limitations and explicit APPROVE or REQUEST_CHANGES verdict. Upon approval, verifies mergeability, marks the PR ready, and merges guarded with `--match-head-commit <sha>`. Administrative overrides (`--admin`) are prohibited.
3. **Policy Changes Authored by AGY:** When AGY authors policy, backlog or documentation PRs, `rootCodex` acts as the independent reviewer, inspecting and authorizing the exact HEAD SHA before AGY performs the merge.

## Evidence

The reviewer posts a substantive PR comment with findings first, tests or inspection performed, limitations, stable reviewer ID, live session identity and the exact full HEAD SHA. Include this machine-readable record after the human-readable review:

```text
<!-- wallmotion-agent-review {"reviewer_id":"AGY","head_sha":"full_40_character_sha","verdict":"APPROVE"} -->
```

Use REQUEST_CHANGES if blocking issues remain. Approval requires actual independent inspection; never approve merely because the author requested it. Optional improvements must be distinguished from bugs.

A new commit invalidates all prior approvals, even if it appears small. The merger must confirm matching SHA, absence of unresolved blocking findings and local validation evidence before executing the merge.

## Merger

The merger must not be the author of the PR under review. It verifies current PR metadata and comments before acting, checks conflicts and branch requirements, then merges only the approved HEAD using `gh pr merge --match-head-commit <sha>`. It must not modify code to resolve conflicts; send conflicts back to the author, who updates the PR and requests a fresh review. No administrative bypasses (`--admin`) or direct main pushes are allowed.

## GitHub account limitation

These agents use the same authenticated GitHub account, richasdev. GitHub does not permit this account to approve its own PR as three distinct reviewers. Therefore, agent decisions are published as PR comments and enforced through the coordination workflow. They are not formal GitHub review approvals and do not provide independent-account authorization. Requiring three native GitHub approvals would require distinct authorized reviewer accounts or an explicitly configured app identity setup.

## Validation

Use the checks appropriate to each change and record their exact commands and results. The billing failure in issue #11 prevents the remote workflow from starting; this is a recorded external limitation, not a passing check. Any configured GitHub required check or branch protection still applies and must not be bypassed.
