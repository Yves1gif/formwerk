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

## 2026-10-17: Design, translations, TestFlight (user: "design all pages, icon, fonts, build them in, upload so I can test on my iPad")
- **Design canvas** (claude.ai artifact "Formwerk App Design", 10 boards): design system, icon, launch, welcome, empty editor, selected face, sketch mode, fillet tool, print sheet, dark mode. The look is "Swiss workshop precision":
  - Werk Blue #1F5FD6 means "act here", Signal Orange #FF8A2A means "picked".
  - Light workspace #ECEEF2 with white glass panels (18 px corners, soft shadow).
- **Fonts:** Space Grotesk (bundled, OFL) for titles; the system font for text; monospaced digits for every number, so values don't jump while dragging. The font is registered at runtime with CoreText, which needs no Info.plist entries on either platform.
- **Icon "the rounded edge":** a white cube on blue with its front edge rounded in orange. That is the first thing you do in the app (a fillet) and also the "selected" colour. Generated by `tools/make-icon.py` in light, dark and tinted variants plus the Mac tile.
- **Minimum iPadOS raised to 18** (from 17) for `DocumentGroupLaunchScene`: a branded start screen with "New Design" and 4 templates. A12 iPads all run iPadOS 18, so no device is lost. The Mac stays at 14 and gets "File → New from Template".
- **Templates:** keychain, open box, wall bracket (L-shape, 2 countersunk M4 holes, inner fillet), plant pot (revolved, drain hole). All are ordinary features, so everything stays editable. The self-test builds all 4 without errors.
- **Selection is orange now, hover is blue** (it was blue/blue).
- **Empty design** shows a "What are you making?" card (Sketch / Box / Import STEP). The sketch's Done/Cancel moved to a top bar.
- **15 languages complete:** 274 strings. `tools/l10n/build-catalog.py` refuses missing strings or changed %@/%lld. The helper agents now write in 4 parts each; the first attempt stalled when a single output got too long.
- **For the App Store:** `PrivacyInfo.xcprivacy` (UserDefaults CA92.1, file timestamps C617.1, no tracking), a launch screen colour, `deploy/deploy.sh` (same as StockStart).
- **README, NOTICE** (OCCT LGPL + relinking instructions, Space Grotesk OFL), first git commit.
- The iPad UI test hung on the home screen while 3 other projects were building on this Mac. The app itself was checked by launching it with `simctl` (the launch screen renders correctly).

## 2026-10-17: App Store Connect, TestFlight, submitted for review (user: "do everything in Chrome … privacy and whatever Apple wants")
- **App record:** "Formwerk: 3D CAD & Print" (Apple ID 6824043658), iOS + macOS, bundle `com.yvesf.formwerk`, SKU `formwerk`, primary language English (USA).
- **App information:**
  - subtitle "Design parts for 3D printing"
  - category Graphics and Design, secondary Productivity
  - no third-party content
  - age rating 4+ (every questionnaire answer "No / None")
- **Privacy:** "Data Not Collected" (published). Privacy policy (EN + DE) in `PRIVACY.md` on GitHub.
- **Price:** free in all 175 countries; available everywhere.
- **Version 1.0 store page:** promotional text, description (EN), keywords, support URL = GitHub issues, marketing URL = GitHub repo, copyright, notes for App Review, review contact (taken from StockStart's entry). "Sign-in required" unticked. **Release set to manual**, so nothing goes live without the user.
- **Screenshots:** 5 × iPad 13" (2064×2752) in `deploy/appstore/`: bracket with a face selected, sketch mode, fillet preview, print sheet, keychain "LEA". They come from the new screenshot mode (`-formwerkShot model|sketch|fillet|print|keychain`). The app sets the scene up by itself; we only launch it with `simctl` and take the picture. This was needed because the user declined simulator control and UI tests would have meant control too. SwiftUI scenes can't be switched conditionally, so screenshot mode presents the editor full screen over the start screen.
- **Version 0.1.0 → 1.0:** the store version and the build's marketing version must match.
- **TestFlight:** internal group "Team" with the user, automatic distribution, builds 0.1.0 and 1.0 ready.
- **Submitted for review** on 17 Oct 2026 at 21:56 (status "Waiting for Review"). The macOS version is still in preparation; it needs its own Mac build upload.

## 2026-10-19: Update (user: "add features, make it more useful, tutorial at opening that people can skip"; "I will click send to Apple myself"; brother tests first)
- **Interactive tutorial (7 steps):** Sketch → rectangle → Done → Extrude → height → fillet → Print. It follows what you actually do, moves on by itself and skips steps you've already done.
  - "Skip tutorial" works on every step.
  - The welcome sheet offers "Show me how (1 min)" or "Skip".
  - It can be restarted under View → Tutorial.
  - Reason: a coach card at the bottom instead of a slideshow, because people learn by doing and can always leave.
- **Lay flat:** select a flat face → the part rotates so that face lies on the bed, centred, at z = 0. It's saved as an ordinary Move step, so it stays editable and undoable.
- **Auto-orient** (print sheet): tries the 6 main directions plus the 12 biggest flat faces as "down" and keeps the one with the least overhang (half of the part's height is added to the score, so lower parts win ties).
- **AR view (iPad)** + **USDZ export:**
  - ModelIO can't write USDZ, and its USDC has no units (USD then assumes cm) and is Y-up.
  - So the USDA is written by hand (`metersPerUnit = 0.001`, Z-up, `subdivisionScheme = none`) and packed as a 64-byte-aligned zip.
  - `usdchecker --arkit`: Success.
- **Templates:** phone stand and wall hook (6 in total). The self-test builds all 6 valid.
- **Mac screenshots:** the app photographs its own window (`-formwerkShotOut`) because Claude has no screen recording permission. This uses an unsandboxed debug copy, since the sandbox container isn't readable from outside. 5 images at 2880×1800 are in `deploy/appstore/mac-*`.
- 33 new texts in all 15 languages (306 strings total). 16 tests green.
- **Not published:** the user submits to Apple themselves. Builds go to TestFlight only.

## 2026-10-23: iPhone Duo (user: "make it run on the iPhone Duo"; "specifically for the iPhone Duo, not normal iPhones, they're too small"; "a store page for iPhone Duo")
- **Decision:** iPhone is now in the build (`TARGETED_DEVICE_FAMILY "1,2"`), but Formwerk is made for the **iPhone Duo's inner screen** (7.6", 1878×2670).
  - With the iOS 27 SDK, that screen reports **regular** width and height, like an iPad, so it gets the full iPad layout (tool rail, inspector, timeline). No separate Duo layout is needed.
- **Narrow iPhone screens** (every normal iPhone, or a Duo while folded) show "Unfold your iPhone" (`UnfoldView`). When you unfold, it disappears by itself because the size class changes.
  - Why not block normal iPhones completely: the App Store can't restrict an app to one iPhone model (there's no device capability for "foldable").
  - Also, an iPhone app that does nothing on a normal iPhone risks rejection (guideline 2.1, app completeness).
  - So a small "Open anyway" button leads to the compact phone layout built earlier (tools at the bottom). It stays usable, it just isn't the main experience.
  - iPad Slide Over (compact on iPad) is untouched and still gets the compact layout.
- **Blocker:**
  - This Mac has **Xcode 26.6**. Apps built with an SDK older than iOS 27 run **letterboxed in iPhone proportions** on the Duo's inner screen. They then stay compact and would show the unfold screen even when unfolded.
  - So: no iPhone build goes to TestFlight or the App Store until Xcode 27.1 is installed. That Xcode also brings the iPhone Duo simulator, needed for real Duo screenshots.
- **Store page for the Duo:** texts and a featuring nomination draft are in `deploy/appstore/iphone-duo.md`. Duo screenshots follow once the Duo simulator exists (Xcode 27.1).
- 4 new strings in all 15 languages (310 total). Checked en/de/ar on the iPhone 17 Pro and iPad 13" simulators. New screenshot mode `-formwerkShot unfold`.
- **Next version backlog:** AI assistant with the user's own AI account (BAUPLAN §12b).
