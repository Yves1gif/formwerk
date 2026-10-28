# Formwerk

**Free 3D design for 3D printing, on iPad and Mac.** Sketch, constrain, extrude, fillet, check and export for your slicer. No account, no cloud, no limits.

- Pencil-first on iPad, mouse/trackpad on Mac
- Sketches with constraints and dimensions, editable history (timeline)
- Extrude, revolve, push/pull, fillet, chamfer, hollow, holes (M2–M8), text, mirror, pattern, combine, split
- Print check (closed solid, overhangs, thin walls, bed size), filament estimate
- Export 3MF, STL, STEP, OBJ; import STEP
- 16 languages

## Build

```bash
tools/build-occt.sh        # builds Open CASCADE 7.9.3 for iPad, simulator and Mac (~50 min)
xcodegen generate
open Formwerk.xcodeproj
```

Tests: `xcodebuild -scheme Formwerk -destination 'platform=macOS,arch=arm64' test`.
Self-test (renders + exports sample parts): `Formwerk.app/Contents/MacOS/Formwerk -formwerkSelfTest`.

## Licence

Formwerk is open source under the [Mozilla Public License 2.0](LICENSE).
It links Open CASCADE Technology (LGPL-2.1 with exception) statically; see [NOTICE.md](NOTICE.md).
