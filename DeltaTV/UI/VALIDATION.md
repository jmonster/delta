# Apple TV acceptance checklist

Import-policy tests pass with Swift 6 strict concurrency checking:
`bash DeltaTVTests/run-import-tests.sh`. Initial Xcode 27 unsigned Simulator/device
builds and Simulator library launch passed. Full focus/control flows, physical
Apple TV behavior and live CloudKit recovery still require the checks below.

Use a ROM you are entitled to test and a development iCloud account/container.
Keep private ROMs out of commits, CI and shared artifacts.

- Start with an empty cache and unavailable iCloud. Show no invented games or
  completed backups; keep Import, Restore, and account errors accessible.
- Navigate every screen with the Siri Remote and a controller. Check visible
  focus, Select/A, VoiceOver labels, long titles, scrolling, and Back behavior.
- Import a valid GB/GBC ROM. Reject HTTP, credential-bearing URLs, unsupported
  files, corrupt/truncated ROMs, oversized streams, and insecure redirects.
  Test timeout, cancellation before/during download, retry, and repeated Select.
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
