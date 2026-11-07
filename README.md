# Eldrum: Untold — Infinite Health research

A reproducible reverse-engineering and local single-player modding workflow for the APK published in this repository's GitHub Release.

## Current target APK

- Release tag: `Aaasa`
- Asset: `com.gotterdammerung.untold.apk`
- Application ID: `com.gotterdammerung.untold`
- Version name/code: `1.11.5 (2592)`
- APK SHA-256: `d57863ea0b01ba1b3162584eea5f839fed22bdd7185a253045af9f7ededd9700`
- Hermes: HBC 98, modern 12-byte function headers

The release asset is downloaded by Actions at run time. APKs and proprietary game code are not committed to the repository.

## Workflow/toolchain

The workflow downloads and verifies:
- OpenJDK 17
- Apktool 3.0.3 (manifest/resources/Smali inspection)
- JADX 1.5.6 (DEX inspection)
- hermes-decomp 0.2.4 (HBC 98 cross-reference, disassembly/HASM export and patching)
- Android SDK Build Tools 36.0.0 (zipalign/apksigner/apkanalyzer)

Run it from **Actions → Eldrum APK analysis → Run workflow**. It downloads the APK from the selected Release, verifies SHA-256 and signature, extracts the JS bundle, searches cross-references to `health`, `alive`, `maxHealth`, `changeHealth`, `_id` and `player`, ranks candidate function IDs and exports their HASM listings.

## Reverse-engineering findings

The first full HBC decompilation identified:
- `Actor` is the base class and owns `health`, `maxHealth`, `alive` and `changeHealth`.
- `Character` (the player) sets `_id = "player"`.
- `Npc` is a separate actor class and uses its own NPC max-health stat.
- Combat damage calls the actor health-change method; story events can also change character health.

This means a global "ignore all negative health changes" patch would make NPCs immortal too. The desired patch must be guarded by the player's `_id` (or by a player-only caller) and must preserve healing and all NPC behavior.

## Patch/build status

**No modified APK is published yet.** The current step exports exact HBC function candidates and HASM so the target function can be inspected. A patch will only be added after its function ID and instruction semantics are confirmed.

The HBC 98 format is modern. The selected `hermes-decomp` release supports function-body patching/resizing for modern HBC, but the resulting bundle still requires verification against the app's embedded Hermes runtime. The pipeline keeps the original APK untouched.

## Distribution and install notes

The modified APK, once built, should be delivered as a short-lived GitHub Actions artifact rather than a public repository commit or Release asset. It must be signed with a new local test key. Android will not accept it as an update over the original app signed by the developer; back up game progress before uninstalling the original to install a differently signed build.

## References

- [Apktool](https://github.com/iBotPeaches/Apktool)
- [JADX](https://github.com/skylot/jadx)
- [hermes-decomp](https://github.com/SymbioticSec/hermes-decomp)
- [Android SDK Build Tools](https://developer.android.com/tools/releases/build-tools)
