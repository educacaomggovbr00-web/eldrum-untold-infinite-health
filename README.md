# Eldrum: Untold — Infinite Health (split-package workflow)

This repository contains a local single-player patch experiment for the Hermes bundle in Eldrum: Untold. It does not distribute the game's APK or proprietary code.

## Important: this app is delivered as split APKs

The source package shown on the device contains multiple required files, for example:

- `com.gotterdammerung.untold.apk` — base APK (contains `assets/index.android.bundle`)
- `config.arm64_v8a.apk` — native libraries for ARM64
- `config.en.apk` — English resources
- `config.mdpi.apk` — screen-density resources
- `manifest.json` and possibly `icon.png` — package metadata

**Do not upload or build from the base APK alone.** A single base APK can pass ZIP and APK-signature checks and still fail on Android with `INSTALL_FAILED_MISSING_SPLIT`. That is what the previous workflow missed.

## Input required before running Actions

1. On the phone, keep the extracted package folder containing all APK split files and `manifest.json`.
2. Compress the folder contents into one ZIP archive. Ensure the ZIP contains the APK files and `manifest.json` (a parent directory inside the ZIP is also accepted).
3. Upload that archive to the GitHub Release `Aaasa` with the exact name `eldrum-untold-splits.zip`.
4. Open **Actions → Eldrum APK analysis and split-package build → Run workflow**. Keep the default release tag and asset name, unless you used another name.

The current Release asset `com.gotterdammerung.untold.apk` is only a single APK and is not sufficient for a split install. The workflow is intentionally fail-fast until the complete archive is uploaded.

## What the corrected workflow does

- Verifies the source archive and requires at least two APKs plus `manifest.json`.
- Checks every split has package ID `com.gotterdammerung.untold`.
- Finds the unique APK containing `assets/index.android.bundle`; this is the only APK whose Hermes bundle is patched.
- Applies the player-only HBC patch to function `25773`.
- Preserves all other split APK contents.
- Zip-aligns and signs every APK split with one shared temporary local test key.
- Verifies every APK, the shared signer certificate, and the package ID.
- Publishes all signed split APKs and a ZIP containing the complete set as a five-day Actions artifact.

## Player-only patch

The current experimental HASM patch targets function `25773` (`Actor.changeHealth`). It checks that the actor's `_id` equals `player` and returns before applying negative health changes. Positive healing and non-player actors should continue through the original code path.

This is a static bytecode-level patch; the workflow's checks do **not** prove the game launches or that the gameplay effect works. A real on-device test is still required.

## Installation

1. Download the Actions artifact `eldrum-untold-infinite-health-split-apks`.
2. Extract the artifact ZIP, then extract `eldrum-untold-infinite-health-splits.zip` (or use the individual APK files already included in the artifact).
3. In SAI or InstallWithOptions, select **all** APK files together in one install session. Never install only the base APK.
4. The split set is re-signed with a local test certificate. It cannot update an installation signed by the original developer. Back up local saves before uninstalling the original app.

## Tools

- OpenJDK 17
- Android SDK Build Tools 36.0.0 (`zipalign`, `apksigner`, `apkanalyzer`)
- hermes-decomp 0.2.4

