# Delta for Apple TV

A development port for **Game Boy and Game Boy Color**, using the existing DeltaCore, GBCDeltaCore and Gambatte engines. It includes native TV navigation, paired-gamepad play, audio/video, in-game saves, one manual save-state slot and optional private iCloud recovery. Existing iOS targets are unchanged. Other systems and Switch2Kit’s custom Bluetooth backend are not enabled.

## Build and run

Use Xcode 26.3 or newer and tvOS 17 or later:

```sh
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init Cores/DeltaCore Cores/GBCDeltaCore
git -C Cores/GBCDeltaCore -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
xcodebuild -project DeltaTV/DeltaTV.xcodeproj -scheme DeltaTV \
  -destination 'generic/platform=tvOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Alternatively, open `DeltaTV/DeltaTV.xcodeproj` and select the `DeltaTV` scheme. No CocoaPods installation or dependency-source rewriting is required. See [dependency pins and compatibility notes](Compatibility/README.md).

Pair an extended game controller in Apple TV Settings. The Siri Remote browses the library; **L1 / LB** pauses gameplay. Menu/Start operates the cartridge’s Start button, while Home remains a system button. Pause offers resume, save/load state and return to library. Failed local saves keep the game paused so you can retry.

Import a direct HTTPS `.gb` or `.gbc` link for a game you are entitled to use. Imports have size, timeout and cartridge checks; archives are unsupported. No games or firmware are included. Keep privately supplied ROMs on the authorized local computer when testing; never commit them, upload them to CI or include them in shared artifacts.

## Saving and iCloud

The default unsigned build is **local-only**. tvOS caches are purgeable; unsynced progress can be lost. A successful local save does not prove a cloud backup succeeded.

Enabling iCloud requires an authorized Apple developer signing configuration and CloudKit container. See [setup and recovery behavior](../Docs/DeltaTVCloudStorage.md) and `Configuration/Cloud.example.xcconfig`. Battery RAM and RTC data share one cloud checkpoint. Conflicts require an explicit choice. This library does not sync with iOS Delta’s existing Google Drive/Dropbox transport.

## Validation

```sh
bash DeltaTVTests/run-storage-tests.sh
bash DeltaTVTests/run-import-tests.sh
```

The new app uses Swift 6 with complete strict-concurrency checking; upstream framework targets retain Swift 5. Thirty storage scenarios and import-policy tests pass.

Initial Xcode 27 unsigned Simulator/device builds passed. The Simulator app opened a privately seeded GB/GBC library; a separate built-framework harness verified real-ROM frame output, non-silent audio samples, input, state reload and battery RAM. ROMs stayed local. The launch-reconciliation update still needs its final Apple build rerun. Physical-controller gameplay, device installation and signed iCloud recovery remain unverified; complete the [acceptance checklist](UI/VALIDATION.md) before release.
