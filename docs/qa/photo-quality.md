# Installed photo dimensions

Issue #116: the background options show oriented source dimensions and the actual prepared CGImage pixel dimensions for the installed photo. Panorama explicitly labels the whole bitmap before monitor crops. Reduced resolution is stated only when a prepared dimension is smaller than its source counterpart.

PhotoQualityInfo retains only IDs, integers and a panorama flag. It reads existing DecodedPhoto metadata at renderer construction; it does not open files, decode again, create players or estimate RAM, HDR, sharpness or energy. Invalid/nonintegral/out-of-range source dimensions cannot trap integer conversion.

Publication follows the existing asynchronous preparation generation and occurs only after renderer installation or reuse. The model accepts matching assignments, removes disconnected/cleared/changed entries and clears values when critical memory pressure releases renderers or the model stops. While replacement of the same wallpaper is pending, the previous installed bitmap remains the reported bitmap.

Temporary-file tests verify actual source/bitmap values, assignment switch, clear, disconnect, critical release/recovery and discarded obsolete preparation. A panorama callback test verifies the installed ID and whole-bitmap marker. A pure projection test keeps source and prepared dimensions distinct and checks invalid dimensions. The optional component snapshot (WALLMOTION_PHOTO_QUALITY_SNAPSHOT) was rendered and visually inspected at 360 points in dark appearance; this is not physical multi-monitor, HDR or VoiceOver certification.
