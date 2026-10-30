# Encoded GIF input budget (issue #133)

The application now rejects known GIF inputs whose complete logical file length exceeds 256 MiB, independently of the existing 256 MiB decoded-frame estimate and 512 MiB estimated global per-view GIF budget. The encoded cap includes extensions, ignored bytes after a trailer and sparse holes. It is a conservative application policy, not a proof that larger GIFs are invalid.

The original structure scanner intentionally stops after a valid trailer. A standalone Rust study accepted a 1×1 GIF with a sparse 512 MiB tail as one frame and four decoded bytes, while APFS allocated 4 KiB for that fixture. This demonstrated the missing input-length policy, not an observed native-decoder leak or OOM.

## Enforcement and compatibility

- New additive Rust/FFI `*_limited` functions accept separate encoded/decoded limits. The file limit is checked from the duplicated descriptor's initial metadata before input reads. Result 4 identifies encoded-size rejection, preserves output and leaves the caller's descriptor/offset unchanged. Existing C symbols, signatures and unlimited-encoded behavior are retained.
- `GIFPreflight` passes the application default for Data/URL/descriptor inspection. Its distinct error includes the actual configured input limit. Managed import checks before creating/copying media and rechecks copied output; restored playback also passes preflight before AppKit decoding.
- Thumbnail generation for `.gif` performs only a Rust regular-file size check before ImageIO. It neither reads content nor repeats the structural scan on each thumbnail size. Format/frame checks remain separate; normal thumbnail output limits still apply.

Limits inspect initial metadata, not a coherent mutable-file snapshot; later path replacement or growth is not prevented. A caller-provided Data buffer already exists before inspection. This does not cap all image formats, native codec scratch, cached/installed surfaces, GPU memory or total RSS, and makes no measured energy/throughput/OOM-prevention claim.

## Verification

Rust tests cover exact encoded boundaries, trailing data, separate frame rejection, old API behavior, FFI output preservation and a sparse file rejected before reading, including a write-only descriptor. The metadata-only check accepts a size-allowed write-only regular file and rejects negative descriptors.

Swift fixtures cover tiny Data/file boundaries and error mapping, an exact-default sparse boundary, one byte over default, unchanged descriptor offset, no import directory/copy callback on rejection and metadata-only behavior distinct from format validation. The native thumbnail fixture rejects an oversized sparse GIF, shrinks it to the real fixture bytes and successfully decodes its 1×1 thumbnail. No large native GIF is decoded and no giant Data buffer is allocated. Sparse allocation behavior is filesystem dependent.
