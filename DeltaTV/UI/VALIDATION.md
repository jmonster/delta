# Apple TV acceptance checklist

Import-policy tests pass with real owned inputs and Swift 6 strict concurrency checking:
`bash DeltaTVTests/run-import-tests.sh`. The final production code passed local
Xcode 27 unsigned Simulator/device builds and actual-ROM automation for GB/GBC,
NES, SNES, GBA, N64 and DS video, input, audio-sample processing, states and saves.
Genesis execution awaits a suitable owned cartridge; firmware rejection passed.
Thirty-eight storage scenarios and 32 fake-radio controller assertions passed.
The reusable controller XCTest bundle builds; local assertions were run through
a private app harness because Xcode could not select the custom simulator set.
Signed-device backup acknowledgment and byte-identical CloudKit recovery also
passed in the Development environment; see [verification scope and remaining
release gates](../../Docs/DeltaTVCloudStorage.md#verification-and-release-gates).

Use a ROM you are entitled to test and a development iCloud account/container.
Keep private ROMs out of commits, CI and shared artifacts.

- Start with an empty cache and unavailable iCloud. Show no invented games or
  completed backups; keep Import, Restore, and account errors accessible.
- Navigate every screen with the Siri Remote and a controller. Check visible
  focus, Select/A, VoiceOver labels, long titles, scrolling, and Back behavior.
- Import a valid cartridge for each linked system. Reject HTTP, credential-bearing URLs, unsupported
  files, corrupt/truncated ROMs, oversized streams, and insecure redirects.
  Test timeout, cancellation before/during download, retry, and repeated Select.
- Exercise official NES/SNES/N64 and Switch 2 GameCube hardware. Verify native
  profiles, complete N64 controls, Sync/handshake, explicit discovery, player
  reassignment and foreground reconnect. Do not infer Bluetooth support from builds.
- Exercise DS right-stick/R2 and D-Pad/A touch, screen bounds, contact/release,
  pause/disconnect/background, and games needing microphone or external BIOS.
- Measure physical N64 performance; the Debug simulator result was about 16 FPS.
- Launch, pause, resume, save, load, cancel loading, and return to the selected
  game. Dismissing an alert must not activate an underlying control.
- Disconnect/reconnect the controller and background/foreground the app.
  Verify safe pausing, no stuck inputs or automatic resume, and repeated actions.
- Finish an iCloud backup, remove the local test cache, relaunch, and restore
  ROM, battery save, and compatible state. Repeat offline, with pending uploads,
  interrupted uploads, and an account change.
- Resolve a two-device conflict using each explicit choice; Cancel must change
  nothing. Verify pending/error status and the warning that retained local
  snapshots remain purgeable.
