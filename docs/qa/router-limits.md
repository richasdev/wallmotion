# Bounded launch-event retention

The launch router admits at most 256 logical URLs across `pendingURLs` plus the current in-flight forwarding batch. A new batch is accepted entirely or rejected entirely before retention. It does not truncate or replace previously accepted events. The capacity reservation moves into the asynchronous forward before pending storage is cleared; a failure releases that reservation and restores the accepted batch at the front, preserving order and staying within the same logical bound. Acknowledged dispatch releases capacity for later events.

This bounds retained logical URL count, not the byte size of incoming arrays/strings, transient array references during restoration, total import bytes, OS event delivery or underlying IPC duration. LibraryModel independently retains its per-import-cycle 256-file cap. Dispatch acknowledgement remains distinct from successful import.

## Rejected batches remain visible

Only a fixed error and the rejected batch count are used in diagnostics; file paths, titles and tokens are not logged. A secondary keeps its startup status window after accepted batches are forwarded if an overflow warning remains. Retry sends accepted/unconfirmed events while keeping that notice. The explicit Exibir Wallmotion e encerrar esta instância action acknowledges the unretained rejected batch and activates/closes only after accepted events are dispatched. Users can instead quit that secondary. A rejected initial file event is distinguished from waiting for an event that has not arrived.

A primary transfers the warning to its library alert through the delegate callback. If rejection happened before admission, becoming primary reports it once. The router does not replay an already transferred primary warning on every future valid event. Rejected URLs are never stored for implicit retry; the message asks the user to select a smaller batch later.

Tests cover startup admission at 256, atomic rejection of one extra event, 200 in flight + 56 pending with another rejection, failed-forward restoration to exactly 256 with original order, successful explicit retry while preserving the warning, oversized initial events and capacity release while a secondary remains open for a notice. All fixtures use synthetic URLs and injected callbacks; no user files or app settings are used.
