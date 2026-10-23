# Formwerk: rules for Claude

- The full plan is in `BAUPLAN.md`. Read it before any work. Scope changes go there first.
- Update `PROJECT-LOG.md` at every step: decisions **and the reasons**, including rejected ideas.
- **Don't build or create the Xcode project until the user says to start.** Then start with phase M0 (OCCT kernel spike).
- Platforms: iPadOS 18+, macOS 14+ (native target) and, since 2026-10-23, iPhone **only for the iPhone Duo's unfolded inner screen** (`TARGETED_DEVICE_FAMILY: "1,2"`). Narrow iPhone screens show the "Unfold your iPhone" screen.
- XcodeGen `project.yml`. This install has no SettingPresets, so Debug/Release settings get written out (copy from `../Paper Trading App/project.yml`). Team HC67GN5D2X, bundle `com.yvesf.formwerk`.
- No paid APIs, no servers, no analytics SDKs. Everything runs on the device.
- Only `Packages/KernelKit` may import OCCT. Everything else uses Swift types.
- Every UI string goes into the String Catalog in all 15 languages. Check German, Arabic (RTL) and Japanese layouts.
