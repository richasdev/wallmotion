# Thermal playback policy

Wallmotion uses Foundation's public `ProcessInfo.thermalState` signal, not a temperature sensor. The preference **Pausar sob pressão térmica** defaults to enabled, including libraries written before this setting existed. Existing library schema remains version 4; the optional setting is decoded with a default and explicit opt-out is persisted.

| OS state | Policy |
| --- | --- |
| nominal | Release thermal pause |
| fair | Keep previous thermal pause state |
| serious / critical | Pause |
| unknown future state | Conservatively treat as serious |

Disabling the preference clears the thermal latch. Re-enabling during fair starts without a thermal pause until the OS reports serious/critical. The latch is process-local, not stored across launches. This hysteresis avoids resuming at the same pressure boundary; it does not guarantee a minimum pause duration or thermal stability.

The model reads the signal before registering `thermalStateDidChangeNotification`, re-reads after registration, and handles subsequent notifications on the main actor. It also refreshes on load/start. No polling timer or private API is used. Stop removes the observer, and start re-reads current state.

Manual, sleep, screen lock/session and low-power pauses remain independent reasons. Cooling never clears the saved manual pause. When an automatic reason remains, the manual action says **Manter pausado** or **Liberar pausa manual**, avoiding a promise that playback will immediately resume.

Existing renderer behavior is preserved: native video pauses; GIF follows its existing pause behavior; web playback disposes its web view to release scripts/resources. Resuming a web embed recreates it and can restart at its configured start timestamp, buffer, or encounter provider errors. No seamless web resume is claimed.

## Verification

Deterministic core tests cover hysteresis, opt-out/reset, manual/system precedence and legacy settings decoding. Model tests inject an OS-state source and post the public notification; they cover initial critical state, notification changes, persistence, manual action labels, observer stop and restart. Other model tests inject nominal state so host thermal pressure does not change their unrelated assertions. Tests do not change OS thermal settings or heat the machine.

Physical high-pressure playback and energy/RSS comparisons remain unmeasured. This is a playback policy, not evidence of measured battery savings, a CPU limit, or hardware thermal protection.

Reference: [Foundation thermal-state notification](https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification), which requires reading `thermalState` before observation.
