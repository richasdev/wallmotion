# Bounded library search (issue #136)

LibraryView now retains at most 4096 UTF-8 bytes for its UI search query, including initialQuery. Oversized input is rejected without truncating or replacing the accepted query. A fixed inline notice does not echo the rejected text. The notice is outside catalog/empty-result conditionals, so it remains visible with an empty library, no matching items or a read-only catalog.

The binding checks the bound before exact UTF-8 identity and updates a local draft copy only for an edit attempt. Identical field reconciliation preserves the notice; a different valid edit clears it. Limpar busca clears query/notice while preserving type/sort; existing Limpar filtros clears query/notice and resets type, preserving sort. Core LibraryQuery remains a generic unrestricted projection. No model save, renderer rebuild, I/O or remote request is added for search input.

Unit cases cover exact/multibyte boundaries, oversized initialization, preserving the last query, exact writebacks, NFC/NFD bytes and explicit clearing of an initially empty rejected query. The optional WALLMOTION_SEARCH_SNAPSHOT_DIR fixture creates its output directory and renders the actual LibraryView with an empty library in dark appearance and a filtered-out video in light appearance. Both notices and clear actions were visually inspected. These captures do not certify physical typing or VoiceOver.

The limit covers retained UI state, not transient TextKit or caller allocations, whole-process RSS or CPU/energy improvements. The warning does not claim a hard process memory cap.
