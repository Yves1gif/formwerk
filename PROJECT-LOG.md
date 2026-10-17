# Project Log: Formwerk (free 3D CAD for iPad and Mac, built for 3D printing)

## Decided
- **2026-10-12: free Shapr3D alternative for iPad and Mac, aimed at 3D printing** (user request). Same core functions, but simpler. iPadOS + macOS only, no iPhone. Folder `Formwerk/`. So far there is only a plan (`BAUPLAN.md`). Nothing gets built until the user says so.
- **Name: Formwerk** (*Form* + *Werk*). Reasons: it sounds Swiss/German-made, works in English, and has no umlaut. A web search on 2026-10-12 found no CAD app with that name. Rejected: Tüftel (umlaut, hard to say abroad), Werkbank (too generic), Werkstück (umlaut), Klotz (sounds like a toy), anything with "Shapr" (trademark, App Store Guideline 2.3.7).
- **Completely free, no ads, no accounts, no servers.** Reasons: the user rejects paid APIs and running costs, ads would ruin a CAD app, and no server means it can stay free forever. iCloud Drive (through document-based app) syncs for free. An optional tip jar unlocks nothing.
- **Geometry kernel: Open CASCADE (OCCT 7.9.x).** Reasons: the only free, mature B-rep kernel with fillets, shells, booleans and STEP. Rejected: Parasolid (Shapr3D's kernel, far too expensive), Manifold (mesh-only: no fillets or STEP, but kept as a helper for mesh import), Truck (too young), our own kernel (years of work).
- **The OCCT license (LGPL) is handled with dynamic frameworks plus a modifiable form of the app.** OCCT's docs name App Store distribution explicitly and require the app to be offered separately in a modifiable form. Recommended: open-source the app (MPL-2.0). This is still open (decision #1 in BAUPLAN §13).
- **Own Swift sketch solver** (Levenberg-Marquardt / Dog-Leg with Accelerate). Reasons: a small, well-understood problem with no license trouble and full control over how dragging feels. PlaneGCS (FreeCAD) is read for ideas only, not copied (LGPL). SolveSpace's solver was rejected (GPLv3).
- **Own Metal renderer instead of RealityKit/SceneKit.** Reasons: CAD needs exact edge lines, pixel-exact picking by face ID and section planes.
- **Native macOS target, not Catalyst.** Reasons: a real menu bar, right-click, mouse-wheel zoom and multiple windows. About 85% of the code is shared. Universal Purchase gives one App Store record.
- **Minimum iPadOS 17 / macOS 14, A12 iPad recommended.** It matches the other projects (iOS 17+). OCCT needs memory. This is still open (decision #3).
- **3MF is the default export** (carries units, colours and multiple bodies, and Bambu/Prusa prefer it). STL, STEP, OBJ and USDZ are also offered.
- **Printing is part of the core, not an add-on:** print check, printer bed presets, auto-orient, filament estimate, fit tolerances, hole compensation and a text tool are all in v1.0. Reason: this is what sets the app apart from Shapr3D for the target group.
- **Sweep, loft, threads and the parameters table moved to v1.1.** Reason: keep v1 achievable. The core first, then extras.
- **Phase M0 is a go/no-go kernel spike before any UI.** Reason: if OCCT doesn't run cleanly on iPadOS, everything else is wasted work.
- **15 languages from day one** (same set as StockStart). The Arabic UI mirrors, but the 3D view and axes don't.

## Open
See BAUPLAN.md §13: open source yes/no, tip jar timing, minimum iPad, final name, GitHub repo.

## 2026-10-15: Start of the build (user: "yes exactly, build first version")
- **Open decisions settled with the defaults** (user said "yes exactly" to the list): open source under MPL-2.0, tip jar later (not in v0.1), minimum iPad with A12 / iPadOS 17, name Formwerk, repo `Yves1gif/formwerk`.
- **OCCT 7.9.3, not 8.0.1.** 8.0 (2026) is a big rewrite. 7.9 is the API Claude knows reliably, and 7.9.3 is its newest bug-fix release. Upgrade later in a dedicated step.
- **OCCT is linked statically, one merged `libOCCT.a` per platform in `OCCT.xcframework`.** Since the app's own code is open source, anyone can relink it with a modified OCCT, which is what the LGPL asks for. Static linking is far simpler than 25 dynamic frameworks. Built by `tools/build-occt.sh` (cmake/ninja from a project venv, since this Mac has no Homebrew). The build tree is deleted after each platform because the disk only had 22 GB free.
- **Only the needed OCCT toolkits:** modelling + STEP. OCCT pulls TKService/TKV3d in for STEP's XCAF on its own, but without OpenGL or FreeType. The Mac build takes 13 min, and the library is 117 MB before linking (the linker keeps only what's used).
- **A plain C facade (`FWKernel.h`) instead of Swift/C++ interop.** OCCT's template-heavy headers would make the Swift compiler slow and fragile. The C API with opaque handles compiles fast and keeps the rule "only Kernel/ knows OCCT".
- **Folders in one Xcode target instead of local Swift packages.** SPM with C++ + a binary xcframework is fiddly. The module boundaries stay as folders (Model, Sketch, Kernel, Engine, Render, Print, App).
- **M0 passed (Mac):** sketch rectangle + circle → extrude → fillet → push/pull → hollow → text → STEP. The volume matches the expected value exactly, and all solids are valid. Editing the fillet radius rebuilds in 55 ms. Making the sketch 50% wider rebuilds every later step correctly.
- **Bug found and fixed:** the rebuild cache never invalidated, because Swift's `Data` hash only reads the first ~80 bytes (all features begin with `{"name":…`). Now every byte is hashed.
- **Face/edge references compare neighbours too.** After a big change, the outer corner edges and the hole edges were about equally close, which caused false "check this step" warnings. Edges now also store the kind and normal of their two neighbouring faces. A warning only appears when the second-best match is almost as good as the best.
- **Sketch faces: the sketch origin is the world origin projected onto the face** (not the face centre). That keeps sketch coordinates stable when the face grows later.

## 2026-10-15: v0.1 builds (state when the usage limit was reached)
- **Mac and iPad (simulator) apps build.** All 16 unit tests pass (solver, regions, kernel volumes, fillet, push/pull + hole, rebuild after a change, text, exports, print check).
- **Self-test** (`Formwerk -formwerkSelfTest`) builds the keychain and box templates, renders them off-screen, picks, runs the print check and exports 3MF/STL/STEP/OBJ. Everything works.
- **Shaders are compiled at runtime from `ShaderSource.swift`.** Reason: Xcode 26 wants an extra Metal Toolchain download to compile `.metal` files.
- **Mac app is Apple-silicon only for now** (OCCT built for arm64 only).
- **Build outside iCloud:** DerivedData goes to `~/Library/Developer/Xcode/DerivedData/Formwerk-cli`. Codesigning fails inside the iCloud Documents folder (Finder metadata).
- **Fixed after the self-test:** invalid `clip_distance` in fragment input (nothing was drawn); lines showing through bodies (the depth offset is now in world space); washed-out lighting.
- **Open:**
  1. The iPad UI test stops at the document browser ("Create Document" button, still loading). That step needs a fix.
  2. 15 translation files (`tools/l10n/<lang>.json`) are being written by helpers. Then run `tools/l10n/build-catalog.py` → `Resources/Localizable.xcstrings`.
  3. README + NOTICE (OCCT LGPL).
  4. git init + push to `Yves1gif/formwerk`.
  5. Test by hand on a real iPad/Mac.
