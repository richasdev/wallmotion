# Shared local media removal

Issue #119: a valid library can contain distinct wallpaper IDs with the same local filename. Removing one entry now preserves that managed copy until the last exact logical reference is removed. Confirmation text explains this case and reads the current record by ID.

Removal resolves the current record instead of trusting a stale caller source. Missing IDs are no-ops. State must save successfully before any deletion; a failed save preserves both state and copies. The original imported source remains untouched.

A temporary-file regression failed against main 6121ae7 because removing the first entry deleted the second entry’s file. After the fix, all 24 LibraryModelTests passed (one optional snapshot skipped), including last-reference deletion, a missing ID, stale caller sources, and failed-save rollback. No user library was used.

Reference matching compares exact MediaSource.local filenames. This does not establish filesystem identity across aliases, case variants, symlinks, or hardlinks, and does not provide orphan collection.
