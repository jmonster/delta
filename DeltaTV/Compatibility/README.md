# DeltaTV compatibility

The standalone project compiles pinned native Delta cores and Switch2Kit directly from submodules. [sources.json](sources.json) records source/header/resource sets and per-configuration build flags; [provenance.json](provenance.json) maps tvOS compatibility copies to original paths and SHA-256 hashes. iOS source files and engine gitlinks are unchanged.

## Pinned sources

| Component | Commit |
| --- | --- |
| DeltaCore | `633dfa86967816315fe19b482511dab1ce517f28` |
| GBCDeltaCore | `0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde` |
| Gambatte | `f8a810b103c4549f66035dd2be4279c8f0d95e77` |
| NESDeltaCore | `c88ef1e7c68ad723194d1b691362ac7d7394f968` |
| SNESDeltaCore | `35add3af36e6c42d777c554a277e098766a78995` |
| GBADeltaCore | `869c34aeca9dd2b3fbd329092bb2743b0ae80c98` |
| N64DeltaCore | `56aefef59d947edbf2eb34b0a0288d751b006f30` |
| MelonDSDeltaCore | `eb9b07ec17307cfd4986cb607f8ee5f6492d73cb` |
| GPGXDeltaCore | `4af2ff5d68cffd12121b63157ffb79267573bfcc` |
| Switch2Kit | `de2514bc687df810ea804449c8d5c0e88c4702bd` |

Original notices and license files remain in the pinned repositories. This port grants no new redistribution rights. No cartridges, external firmware, skins or personal test assets are packaged.

## Target selection and adaptations

The app and added targets use tvOS 18/arm64. The app explicitly disables Xcode’s Debug dylib stub so its development executable loads directly on physical tvOS. Native engine sources and required resources come from the upstream Xcode targets or GPGX/SDK package source sets. Per-target header search paths are explicit and header maps are disabled for added cores, avoiding collisions between their `Platform.h`, module maps and private math headers. C++ standards follow the engines’ requirements. N64/MelonDS native Debug engines use optimization level 2; the UI remains debuggable.

DeltaCore’s five compatibility copies provide playback audio, scene-focus checks, purgeable cache storage, skin-free rendering and native controller callbacks. The GBC copies preserve atomic SRAM/RTC handling and bounded frames. GB/GBC revision identifiers remain compatible with the earlier port.

- NES uses native Nestopia, without the unavailable WebKit fallback. Its checkpoint/restart adapter preserves SRAM, inputs and native save-state results; player indices are bounded.
- SNES uses Snes9x. Compatibility copies expose load/save results, avoid process exit on load failure, guard empty audio buffers and atomically publish SRAM. Two comparator declarations are const-correct for current libc++; every C++ translation unit force-includes that guarded compatibility header to keep class definitions consistent.
- GBA uses VBA-M without CoreMotion on tvOS. Frames are bounded, save operation results are exposed, and EEPROM size/use flags are restored with 512/8192-byte saves to avoid truncating an 8 KiB checkpoint on the next write.
- N64 uses Mupen64Plus, GLideN64 and RSP-HLE with a cached interpreter, not JIT. Plugin frameworks retain their dynamic loading interface. Core/plugin startup and shutdown are paired, waits are bounded, and a timed-out engine is not reused. A versioned binary-plist battery checkpoint includes SRAM, EEPROM, FlashRAM and four memory packs, validated completely before restoration. Legacy iOS raw N64 save migration is not implemented.
- DS uses melonDS direct boot and its replacement BIOS. DS-compatible enhanced cartridges run in DS mode; DSi-only boot, external firmware setup, microphone capture, Wi-Fi and JIT are excluded. Per-game cached save data is reset. The app supplies normalized stylus input to the lower screen.
- Genesis uses Genesis Plus GX’s native source set. It accepts Mega Drive cartridges only; import and native loading reject Sega CD firmware/Pico. Load/save results, strict save lengths and missing-buffer guards prevent reporting an unsupported image as a valid game.
- Switch2Kit is built from the existing iOS package pin, with its package name preserved for access control. No SDK fork, macOS Bluetooth helper or Apple credential setup is added. The tvOS service reuses Delta’s adapter and mapping, with two direct Bluetooth slots and foreground lifecycle cancellation. The native provider keeps Nintendo NES/SNES mappings and excludes the Siri Remote from gameplay.

## Verification boundary

See [runtime qualification](../README.md) and [acceptance gates](../UI/VALIDATION.md). Real cartridges verified GB/GBC, NES, SNES, GBA, N64 and DS. Genesis cartridge execution remains unverified because no suitable local input was found; unsupported firmware rejection passed. Native Nintendo controller mappings and the Switch2Kit radio handshake require physical hardware testing. Compilation and fake-radio checks are not Bluetooth evidence.
