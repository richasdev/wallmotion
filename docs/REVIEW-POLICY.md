# PR review policy

Every change goes through a PR, three independent agent reviews and a separate merger. This policy was explicitly requested by the user on 2026-10-30 and applies to documentation and maintenance as well as code.

## Evidence

Each reviewer posts a substantive PR comment with findings first, tests or inspection performed, limitations, its stable reviewer ID, live Dispatch/session identity and the exact full HEAD SHA. Include this machine-readable record after the human-readable review:

```text
<!-- wallmotion-agent-review {"reviewer_id":"BUG-HUNTER-1","dispatch_id":"dispatch_from_live_preamble","head_sha":"full_40_character_sha","verdict":"APPROVE"} -->
```

Use REQUEST_CHANGES if blocking issues remain. Approval requires actual independent inspection; never approve merely because another reviewer or the author approved. Optional improvements must be distinguished from bugs.

A new commit invalidates all prior approvals, even if it appears small. The coordinator must confirm distinct runtime sessions, matching SHA, absence of unresolved blocking findings and local validation evidence before authorizing the merger for a named PR and SHA. Runtime/task records establish which agent produced each comment; the comment marker alone is not authentication.

## Merger

The merger is a fourth agent, distinct from authors and reviewers. It verifies current PR metadata and comments before acting, checks conflicts and branch requirements, then merges only the approved HEAD using `gh pr merge --match-head-commit <sha>`. It must not modify code to resolve conflicts; send conflicts back to the author, who updates the PR and requests three fresh reviews. No administrative bypasses or direct main pushes are allowed.

## GitHub account limitation

These agents use the same authenticated GitHub account, richasdev. GitHub does not permit this account to approve its own PR as three distinct reviewers. Therefore, agent decisions are published as PR comments and enforced through the coordination workflow. They are not formal GitHub review approvals and do not provide independent-account authorization. Requiring three native GitHub approvals would require distinct authorized reviewer accounts or an explicitly configured app identity setup.

## Validation

Use the checks appropriate to each change and record their exact commands and results. The billing failure in issue #11 prevents the remote workflow from starting; this is a recorded external limitation, not a passing check. Any configured GitHub required check or branch protection still applies and must not be bypassed.
