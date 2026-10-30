# Exact input reconciliation (issue #135)

Swift String equality compares canonical Unicode equivalence. That is insufficient for editable URL bytes: NFC café and NFD cafe + combining acute produce different percent-encoded paths. The old equality guard ignored that edit. It also ran before the byte limit, allowing a canonically equivalent over-limit paste to skip its rejection notice.

URLInputDraft and RenameDraft now check their existing bounds first, then compare UTF-8 byte identity. An exact writeback preserves prior input/storage errors. A different valid byte sequence is an edit; an oversized attempt preserves the prior bounded value and sets its error. Their return value distinguishes an edit attempt from reconciliation so both SwiftUI bindings can clear storage errors without an earlier canonical comparison. No URL normalization or silent truncation is introduced; title normalization remains a separate model contract.

Four deterministic regressions failed on main 45915bb (nine assertions): a small NFC/NFD URL edit, an oversized canonically equivalent URL, a one-grapheme name with decomposing marks, and a valid differently encoded edit acknowledging an earlier rejection. Tests construct long forms manually and assert UTF-8 identity/percent-encoded URL output, rather than relying on String equality. The cases retain only a few KiB and do not contact a server. Existing same-value writeback regressions remain in place.

The bound covers retained draft state, not all transient text-system allocation. No CPU benchmark, URL-server equivalence or new OOM-prevention guarantee is claimed.

Optional URL snapshots create their configured output directory before opening fixture windows. URL and rename captures verify that initial oversized-input notices survive real field reconciliation and Save stays unavailable. Captures are component QA, not physical typing or VoiceOver certification.
