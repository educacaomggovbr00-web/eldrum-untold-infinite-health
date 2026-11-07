# Player-only infinite-health patch

- Target: HBC function **25773**, confirmed from the decompiled `Actor.changeHealth` closure.
- Guard checks `actor._id === "player"`.
- If the amount parameter is negative (damage), the function returns before changing health.
- Positive changes/healing still use the original code.
- NPCs do not have `_id === "player"`, so their original damage calculation remains unchanged.
- The patch uses `GetByVal` to read `_id`, avoiding a new inline-cache slot in the HBC function header.
- Original HBC body and original APK are kept intact; the patch file contains only an edited HASM copy.

This is a static bytecode-level patch. GitHub Actions verifies that the patched bundle can be parsed and re-disassembled, that the APK is repacked/zip-aligned/signed, and that the package ID and APK signature are valid. **It still needs an in-game test on the Moto G35** to confirm runtime behavior.
