# Panorama compatibility

Issue #123: entering panorama from video, GIF or official web now starts an empty panorama instead of rejecting the organization change. A local photo is inherited; independent assignments and framing remain stored for return to separate mode. The empty panorama explains that a local photo must be selected. Explicitly applying incompatible media still fails before persistence.

Wallpaper.supportsPanorama centralizes the existing local-photo requirement for model transitions, stored-state validation and coordinator validation. No animated spanning support is introduced. Existing geometry, GIF budgets and write-failure protections remain in force.

Temporary-library tests exercise video, GIF and official YouTube transitions, photo inheritance, direct video rejection, independent-state restoration and per-mode application availability. These do not certify physical multi-monitor rendering.

Issue #124: incompatible cards now disable only their Apply action in panorama, with an explanatory tooltip/accessibility hint. Rename and removal remain available. Availability resolves the current library record, rejects missing/disconnected targets and allows all supported media in independent/mirrored modes. Direct model validation remains the final protection. VoiceOver and physical pointer QA remain manual.
