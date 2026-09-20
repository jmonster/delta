# Switch 2 controllers

Delta consumes the **Switch2Kit Swift package product** directly. Open the normal
`Delta.xcworkspace`; there is no preparation script, alternate project, source
copy, replacement package manifest, or modified DeltaCore checkout.

This fork's Delta app requires **iOS/iPadOS 18 and Xcode 26 / Swift 6.2 or newer**.
Switch2Kit uses Synchronization.Mutex; other Delta targets retain their existing
minimum OS versions. The package reference and Package.resolved select the same
SDK revision. Its iOS portability change is reviewed in Switch2Kit PR #78.

## Use

In Settings → Controllers → Switch 2 Controllers, choose Find and hold Sync.
Bluetooth access is requested only after Find. Assign players and customize
controls through Delta's existing controller settings. Discovery lasts 60 seconds;
Disconnect All stops support. Returning from the background requires Find again.

Pro and GameCube retain labeled face buttons, D-pad, both sticks, and digital
trigger clicks. Plus is Start; Home is Delta's menu. Minus is Select on Pro;
Capture is Select on GameCube. GameCube analog travel does not synthesize clicks.
Individual Joy-Con halves are horizontal, stick on the left, with SL/SR shoulders;
left Capture/right Home opens the menu. Sticks have a 15% radial dead zone.

## Ownership and tests

GameControllerRegistry combines native controllers with app-provided controllers
and allocates players across both. DeltaCore's own native/keyboard manager is not
patched. The Switch2Kit service owns explicit discovery and scene lifecycle; its
adapter feeds typed MFi inputs to DeltaCore's existing receiver machinery. On an
interruption the observer is cancelled before inputs are released. Resume creates
a fresh observer and consumes its initial snapshot instead of mixing a live
snapshot with a backlog. Connection identity and report sequence reject stale input.

Run the **Switch2ControllerTests** scheme on an iOS Simulator. Its tests substitute
only the radio, using real SDK value types and production registry, service,
mapper, adapter, and DeltaCore sustained-input/receiver behavior. CI also builds
the complete Debug Simulator and Release device apps from the normal workspace.

Physical pairing/gameplay still require checking each model/firmware on an iPhone
or iPad, including permission retry, multiplayer/remapping, reconnect, Bluetooth
loss and held-input release. iOS exposes no local adapter address, so automatic
button-wake reconnection is not promised; use Find/Sync. Combined Joy-Cons, motion,
mouse, game rumble, analog-trigger output, stick-click/rear bindings, USB, NFC and
audio are not implemented. Unsigned device compilation is not an installable IPA.
