# Removal confirmation wording

The confirmation now follows MediaSource: local entries explain deletion of the imported managed copy with the original preserved; both direct remote URLs and provider embeds explain removal of the link from the library/monitors. The message is derived only from the selected pending item's source and does not interpolate paths, URLs or tokens. Dismissed state has no message.

Only presentation copy changes. LibraryModel.remove, state publication, renderer cleanup and managed-file deletion remain unchanged. Existing local-original-preservation and remote-no-file-deletion tests cover those effects in the regression suite. Native dialog presentation/VoiceOver remains manual QA.
