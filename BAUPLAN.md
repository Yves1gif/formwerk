# Formwerk: Bauplan

**Free 3D CAD for iPad and Mac, built for 3D printing.**
Status: plan only. Nothing has been built yet (2026-10-12).

---

## 1. The name

**Formwerk** = *Form* (shape) + *Werk* (works, workshop). It sounds Swiss/German-engineered, is easy to say in English, and has no umlaut (safe for the App Store, URLs and file names).

- App Store name: **Formwerk: 3D CAD & Print** (30 characters max, so this fits)
- Home screen name: **Formwerk**
- Subtitle: *Design parts for 3D printing*
- Bundle ID: `com.yvesf.formwerk`
- Document type: `.formwerk` (UTI `com.yvesf.formwerk.document`)
- A quick search on 2026-10-12 found no CAD app called Formwerk. Before submitting, check the App Store name and the trademark registers (Swissreg, EUIPO, USPTO).

Names that were considered and rejected:

| Name | Why not |
|---|---|
| Tüftel | Lovely Swiss word, but the umlaut breaks in many places and nobody outside DACH can say it |
| Werkbank | Too generic, hard to rank in search |
| Werkstück | Umlaut, and it sounds like a manual |
| Klotz | Sounds like a toy and puts serious users off |
| Anything with "Shapr" | Trademark risk. Apple also rejects competitor names in metadata (Guideline 2.3.7) |

---

## 2. The idea in one paragraph

Shapr3D proved that CAD on an iPad with an Apple Pencil works and feels great. But it is expensive, and its free plan is heavily limited. Formwerk does the **80% of Shapr3D that hobbyists and makers use for 3D printing**: sketch, constrain, extrude, fillet, combine, print-check and export. It is **completely free, with no limits, no account and no cloud**. It is simpler because every tool only shows up when it makes sense for what you've selected, and because printing is part of the core instead of an afterthought.

### Principles (these break ties when we disagree)

1. **Free and unlimited.** No design limits, no low-res export, no watermark, no ads.
2. **No servers and no paid APIs.** Everything runs on the device. Sync goes through iCloud Drive (free). There are no running costs, so the app can stay free forever.
3. **Print-first.** Every model is a printable solid in millimetres by default. Export is one tap.
4. **Pencil-first on iPad, mouse/trackpad-first on Mac.** No ported UI: each platform gets its own input design.
5. **Simple beats complete.** When a feature would make the main flow harder, it waits for a later version.
6. **Every string in all 15 languages** from day one (German, Arabic and Japanese layouts get checked).

### Who it's for

- **Makers with a 3D printer** (Bambu, Prusa, Creality…) who want to design brackets, boxes, holders, replacement parts and name tags without learning Fusion 360.
- **Students and schools** with iPads. The app is free and needs no account, which keeps it in line with school privacy rules.
- **Designers** who want quick, precise concept models on the iPad.

### Who it's *not* for (v1)

People who need assemblies with joints, 2D production drawings, sheet metal, CAM or team collaboration. They should use Fusion, Onshape or Shapr3D.

---

## 3. Feature scope

### v1.0: the core (App Store launch)

**Sketching (2D)**
- Line / polyline, rectangle (2-point, centre), circle (centre, 3-point), arc (3-point, tangent), polygon (n sides), slot, fit-point spline, point
- Offset, trim / extend, 2D corner fillet, sketch mirror, construction-line toggle
- Project edges from the 3D model onto the sketch plane
- Sketch on any planar face or construction plane
- Closed regions are detected automatically and can be tapped to extrude (as in Shapr3D)

**Constraints and dimensions**
- Coincident, horizontal, vertical, parallel, perpendicular, tangent, equal, concentric, midpoint, symmetric, fixed
- Dimensions: distance, horizontal/vertical distance, angle, radius, diameter
- Constraints are inferred while drawing (snap to horizontal, to endpoints, tangent), shown as small glyphs
- Colour shows the state: blue = still movable, black = fully defined, red = over-defined (with "remove conflicting constraint")
- Number input takes maths and units: `20+5`, `50/2`, `1in`, and the decimal comma (`12,5`) in German and French

**Solids (3D)**
- **Extrude / Push-Pull**: tap a region or face and drag the arrow, or type the distance. Each extrude can create a new body, join, cut or intersect. The app picks the most likely one automatically: pulling out joins, pushing in cuts.
- Revolve
- Fillet and chamfer (on edges, with a live preview while dragging)
- Shell (hollow with wall thickness, with optional open faces)
- Booleans: union, subtract, intersect
- Split body by plane or face
- Mirror, linear pattern, circular pattern
- Move / rotate / scale with a 3D gizmo, and snapping to grid and angles
- Offset face (direct modelling: move a face and the solid follows)
- **Hole tool**: simple, counterbore, countersink, with metric screw presets (M2–M8)
- Construction planes (offset, angled, through 3 points) and axes

**Inspection**
- Measure (distance, angle, radius, area)
- Section view (cut the model with a plane)
- Volume, surface area, bounding box
- X-ray / transparency toggle

**History**
- Feature timeline at the bottom: every step can be edited later (change a dimension and the model rebuilds)
- Unlimited undo / redo
- Multiple bodies per design, each with a colour

**3D printing (the differentiator, see section 7)**
- Export **STL** (binary), **3MF** (with units and body colours), **OBJ**, **STEP**, **USDZ** (AR Quick Look)
- Import STL, 3MF, OBJ (as reference meshes) and STEP (as editable solids)
- **Print check**: closed/manifold, thin walls, overhangs, tiny details, model larger than the printer bed
- Printer bed presets with a "does it fit?" preview
- Filament estimate in grams and metres
- Fit/tolerance presets (press fit, snug, loose)
- **Text tool**: write text with any installed font and emboss or engrave it on a face. Name tags and labels are among the most common things people print.
- "Open in…" sends the file straight to Bambu Handy / Bambu Studio / PrusaSlicer / OrcaSlicer through the share sheet

**App**
- Document browser (Files app, iCloud Drive), thumbnails, duplicate/rename
- 5 interactive tutorial projects (see 6.6)
- Templates: blank, box with lid, wall bracket, keychain, plant pot
- Units: mm (default), cm, m, inch
- Dark and light mode
- 15 languages

### v1.1: soon after launch
- Sweep and loft
- Printable **threads** (metric, with print tolerances)
- **Parameters table**: named variables (`wall = 2mm`) used in any dimension
- Draft angle
- Emboss text and images on curved faces
- Per-face colours for multi-colour 3MF (Bambu AMS / Prusa MMU)
- Mesh to solid: turn simple imported STLs into editable bodies
- Apple Pencil Pro: squeeze for the tool palette, barrel roll to rotate the gizmo

### v2: later (only if v1 is loved)
- 2D drawings (PDF/DXF) with dimensions
- Light assemblies (several parts, simple joints, exploded view)
- Shortcuts / App Intents ("Export all designs as 3MF")
- Apple Vision Pro: view the model at real size
- Sketch from a photo (trace over an imported picture, done locally)

### Never (deliberately)
Cloud accounts, team collaboration, CAM/CNC toolpaths, rendering studio, sheet metal, AI features that need paid APIs, subscriptions.

---

## 4. Technical architecture

### 4.1 Stack

| Layer | Choice | Why |
|---|---|---|
| Language | Swift 6 + C++17 (only inside the kernel wrapper) | Swift/C++ interop (Xcode 15+) lets us call the C++ kernel without an Objective-C++ bridge |
| UI | SwiftUI, with UIKit/AppKit for the 3D view and Pencil input | Shared code across iPad and Mac. Native views where precision matters |
| 3D graphics | **Metal** (own renderer) | RealityKit/SceneKit are built for scenes, not CAD: we need exact edges, picking by face ID and section planes |
| Geometry kernel | **Open CASCADE Technology (OCCT) 7.9.x**, see 4.3 | The only free, mature B-rep kernel: fillets, shells, booleans, STEP |
| Sketch solver | **Own Swift solver** (see 4.4) | Small, well-understood problem. No license trouble. Full control over the UX |
| Maths | Apple Accelerate (LAPACK, sparse) and `simd` | Free, fast, on-device |
| Documents | `DocumentGroup` / `ReferenceFileDocument`, file package | Free iCloud Drive sync, Files app integration and versions without our own server |
| Project | **XcodeGen** `project.yml` (same as Sky Routes, StockStart) | Same setup as the other projects. This install has no SettingPresets, so Debug/Release settings get written out |
| Platforms | **iPadOS 17.0+** and **macOS 14.0+**, native macOS target (not Catalyst). **No iPhone** | Universal Purchase: one App Store record, both platforms |

**iPad only, not iPhone:** set `TARGETED_DEVICE_FAMILY: "2"`. CAD on a phone screen would hurt the reviews. iPhone may come later as a viewer.

**Changed 2026-10-23: iPhone Duo.** The build now includes iPhone (`"1,2"`), but it's made for the **iPhone Duo's inner screen**, which has regular size classes like an iPad and gets the full iPad layout. Normal iPhones and a folded Duo show an "Unfold your iPhone" screen. A small "Open anyway" button leads to the phone layout. See PROJECT-LOG.

**Native Mac rather than Catalyst:** real menu bar, right-click, mouse-wheel zoom and multiple windows feel right on a Mac. Roughly 85% of the code is shared, and only the input layer and window chrome differ.

### 4.2 Modules (local Swift packages)

```
Formwerk/
├── App/                    SwiftUI app: iPad and Mac targets, screens, toolbars
├── Packages/
│   ├── FormwerkModel/      Document, features, timeline, parameters, units (pure Swift, fully tested)
│   ├── SketchKit/          2D geometry, constraint solver, region detection, snapping
│   ├── KernelKit/          Swift API over OCCT (C++ facade + Swift wrapper, runs on its own actor)
│   ├── RenderKit/          Metal renderer, camera, picking, gizmos, section planes
│   ├── PrintKit/           Mesh export/import (STL/3MF/OBJ), print check, bed presets, filament estimate
│   └── InputKit/           Pencil/touch gestures (iPad) and mouse/trackpad/keyboard (Mac) → common commands
├── Vendor/
│   └── OCCT/               build script + built xcframeworks (not in git, built by script)
├── Tests/
├── tools/                  build-occt.sh, test models, localisation checks
└── deploy/                 archive/upload scripts (like StockStart)
```

How data flows:

```
Pencil / mouse ──► InputKit ──► Command (e.g. "extrude region 3 by 10 mm")
                                   │
                                   ▼
                           FormwerkModel (adds a feature to the timeline, undo step)
                                   │
                                   ▼
                     KernelKit actor (OCCT rebuilds the changed features)
                                   │  shapes + meshes (tessellated)
                                   ▼
                     RenderKit (Metal draws faces, edges, highlights)
```

**Rule:** only `KernelKit` knows about OCCT. Everything above it speaks Swift types (`BodyID`, `FaceRef`, `Mesh`). If we ever swap the kernel, only one package changes.

### 4.3 Geometry kernel: the most important decision

| Option | B-rep (exact) | Fillet/shell | STEP | License | Maturity | Verdict |
|---|---|---|---|---|---|---|
| **OCCT** | ✅ | ✅ | ✅ | LGPL-2.1 + exception | 30 years, used by FreeCAD | **Chosen** |
| Manifold | ❌ (mesh) | ❌ | ❌ | Apache-2.0 | Very robust booleans | Use as a helper for mesh import/repair |
| Truck (Rust) | ✅ | partial | partial | Apache/MIT | Young | Too risky for v1 |
| Parasolid (Shapr3D's kernel) | ✅ | ✅ | ✅ | Commercial, very expensive | Best | Not possible for a free app |
| Our own kernel | – | – | – | – | Years of work | No |

**OCCT and the App Store (LGPL).** OCCT's own documentation covers this case: when an app ships through the App Store, OCCT can't be swapped by the user. The app must then also be **offered separately in a modifiable form**, with everything needed to run it with a modified OCCT. Our plan:

1. Build OCCT **unmodified** (or publish every patch) as **dynamic frameworks** inside the app.
2. Show the LGPL notice and a link to the OCCT source on the About screen.
3. **Recommended:** make Formwerk's own code **open source** (MPL-2.0) on GitHub. That fully satisfies the "modifiable form" requirement, costs nothing, and builds trust with makers ("free and open"). Alternative: keep the repo private and publish a "relink kit" (object files + build instructions) for every release. That is more work each time, and the legal side is less clear-cut.
4. This is **open decision #1** (see section 13).

**OCCT parts we need** (only these, which keeps the app small, roughly 25–40 MB):
FoundationClasses (TKernel, TKMath), ModelingData (TKG2d, TKG3d, TKGeomBase, TKBRep), ModelingAlgorithms (TKGeomAlgo, TKTopAlgo, TKPrim, TKBO, TKBool, TKFillet, TKOffset, TKFeat, TKMesh, TKShHealing), DataExchange (TKDE, TKXSBase, TKDESTEP, TKDESTL, TKDEOBJ).
**Not needed:** Visualization, Draw, FreeType (we draw with Metal and get text outlines from CoreText).

**Which OCCT function does each tool use:**

| Formwerk tool | OCCT |
|---|---|
| Extrude / Push-Pull | `BRepPrimAPI_MakePrism`, `BRepFeat_MakePrism` |
| Revolve | `BRepPrimAPI_MakeRevol` |
| Fillet / Chamfer | `BRepFilletAPI_MakeFillet` / `MakeChamfer` |
| Shell | `BRepOffsetAPI_MakeThickSolid` |
| Booleans / split | `BRepAlgoAPI_Fuse / Cut / Common / Splitter` |
| Mirror, pattern, move | `gp_Trsf` + `BRepBuilderAPI_Transform` |
| Offset face | `BRepOffsetAPI_MakeOffsetShape` / `LocOpe` |
| Hole | sketch profile + revolve + cut |
| Sweep / Loft (v1.1) | `BRepOffsetAPI_MakePipeShell` / `ThruSections` |
| Tessellation for display/STL | `BRepMesh_IncrementalMesh` |
| Volume, centre of mass | `BRepGProp` |
| Repairing imports | `ShapeFix_Shape` |
| STEP in/out | `STEPControl_Reader / Writer` |

**Threads:** OCCT isn't thread-safe when two threads share a shape. That's why `KernelKit` is one Swift `actor`: all operations run there in order, and the UI never waits on it. Long operations show progress and can be cancelled (`Message_ProgressRange`).

### 4.4 Sketch constraint solver (own code)

- **Unknowns:** point coordinates, radii, angles. **Equations:** each constraint is one or two equations, e.g. *parallel* = cross product of the directions = 0.
- **Method:** Levenberg-Marquardt / Dog-Leg with a sparse Jacobian (Accelerate). The current position is the starting point, so the sketch moves as little as possible.
- **Degrees of freedom:** a rank check (QR) tells us which points can still move (blue) and which are fixed (black). It also finds redundant and conflicting constraints (red).
- **While dragging:** the dragged point becomes a soft "goal", so dragging feels smooth.
- **Target:** a sketch with 200 entities solves in under 5 ms.
- **References:** FreeCAD's PlaneGCS for the maths. We read it for ideas but don't copy code (LGPL).

### 4.5 History and the "topological naming" problem

When you change an early dimension, faces get new internal numbers. A later fillet then "loses" its edge. This is the classic CAD problem that also breaks FreeCAD models.

Plan (simple, but robust enough):
1. Every feature stores **references with a signature**, not just an ID: face type, normal, centre, area, and the neighbouring faces. After a rebuild, the most similar face is chosen.
2. OCCT's history tools (`BRepBuilderAPI_MakeShape::Generated/Modified`) are used to follow faces through each operation.
3. If no match is safe enough, the feature gets a **yellow warning** in the timeline ("pick the edge again") instead of silently doing something wrong.
4. Test suite: 30 standard models in which early dimensions get changed, and every later feature must still land on the right face.

### 4.6 File format `.formwerk`

A **package** (folder that looks like one file):

```
MyBracket.formwerk/
├── manifest.json        format version, app version, units, created/changed
├── timeline.json        all features in order with parameters (this is the real model)
├── sketches/*.json      sketch geometry and constraints
├── cache/bodies.brep    rebuilt result (optional: makes opening fast, can be deleted)
├── cache/preview.mesh   display mesh for instant opening
└── thumbnail.png        for the Files app and the document browser
```

- `timeline.json` is the source of truth. The cache can always be rebuilt from it.
- New fields are optional on decode (no migrations, same lesson as StockStart's `account.json`).
- Text-based files mean iCloud can sync them and conflicts are easy to handle.

### 4.7 Rendering (Metal)

- Faces as triangles with a smooth CAD look (soft lighting, light ambient occlusion), **edges as clean screen-space lines**, silhouettes
- **Picking:** a second pass writes face/edge/body IDs into an integer texture. Tapping reads one pixel, which is exact and fast
- Highlights for hover (Pencil hover on M2+ iPads, mouse on Mac) and selection
- Infinite grid, view cube, orthographic/perspective, zoom to fit, standard views
- Section plane and X-ray
- **During a drag:** coarse mesh for live preview, fine mesh when you let go
- **Targets:** 120 fps on iPad Pro/M-series Macs, 60 fps on an iPad with an A12, models up to 1 million triangles

---

## 5. Supported devices

- **iPad:** iPadOS 17+, Apple Pencil (1st gen, USB-C, 2nd gen, Pro). The app works without a Pencil too (finger mode).
- **Mac:** macOS 14+, Apple silicon and Intel (universal build). Mouse, trackpad, keyboard.
- **Minimum recommended:** iPad with an A12 chip or newer (3 GB RAM). OCCT plus large models need memory. Older devices get a "large models may be slow" note.

---

## 6. UX design

### 6.1 Screen layout (iPad, landscape)

```
┌──────────────────────────────────────────────────────────────────┐
│ ◀ Designs   MyBracket      ↶ ↷               ⧉ View   ⤓ Export │  top bar
├────┬─────────────────────────────────────────────────┬───────────┤
│ ✏️ │                                                 │ Inspector │
│ ⬛ │                                                 │           │
│ ◯ │                  3D viewport                    │ Width     │
│ ⤒ │                                                 │ 40 mm     │
│ ◐ │            ┌─ context menu ──────┐              │ Fillet    │
│ ⧉ │            │ Extrude  Fillet  ⋯  │              │ 2 mm      │
│ 🖨 │            └─────────────────────┘              │           │
├────┴─────────────────────────────────────────────────┴───────────┤
│ ● Sketch1 ─ ● Extrude1 ─ ● Fillet1 ─ ● Hole1 ─ ● Shell1     ▶    │  timeline
└──────────────────────────────────────────────────────────────────┘
```

- **Left:** tool groups: Sketch · Solid · Transform · Construct · Inspect · Print
- **Context menu next to the selection** (the key to "simpler"): it only shows tools that fit what's selected. Select an edge → Fillet, Chamfer. Select a region → Extrude, Revolve.
- **Right:** inspector with the numbers for the current tool. It folds away when nothing is selected.
- **Bottom:** timeline. Tap a step to edit it. Drag the end marker back to see earlier states.
- Portrait mode: tools become a bottom bar, and the inspector becomes a sheet.

### 6.2 iPad input (Pencil + fingers)

| Action | Gesture |
|---|---|
| Draw, select, drag | **Pencil** |
| Orbit | 1 finger drag |
| Pan / zoom | 2 fingers drag / pinch |
| Undo / redo | 2-finger tap / 3-finger tap |
| Tool palette at the tip | Pencil double-tap (2nd gen) / squeeze (Pro) |
| Snap preview | Pencil hover (M2+ iPads) |
| Multi-select | hold a finger on the screen while tapping with the Pencil |
| Without a Pencil | "Finger mode" switch: 1 finger draws, 2 fingers orbit |

Shortcuts work with a Magic Keyboard (same as on Mac).

### 6.3 Mac input

- Mouse: **right-drag orbit, middle-drag pan, wheel zoom** (default). Presets in the settings: *Fusion 360*, *SolidWorks*, *Blender*, *Shapr3D-like*.
- Trackpad: 2-finger swipe orbits, pinch zooms, shift + swipe pans.
- Keys: `L` line, `R` rectangle, `C` circle, `A` arc, `D` dimension, `E` extrude, `F` fillet, `H` hole, `M` measure, `Space` repeat the last tool, `Esc` cancel, `⌘Z / ⇧⌘Z`, `F` with nothing selected = zoom to fit.
- Real menu bar with every command (plus its shortcut), right-click context menu, several windows (one design each).

### 6.4 The main flow (how a design is made)

1. Tap **Sketch**, then tap the grid or a face → the view turns to face the plane.
2. Draw a rectangle → constraints appear on their own. Tap a side → type `40` → done.
3. Tap the rectangle → **Extrude** → drag up or type `10`.
4. Tap an edge → **Fillet** → drag to `2 mm`.
5. **Print** → check (green) → Export 3MF → Open in Bambu Studio.

**Goal: a new user prints their first part within 10 minutes of first opening the app.**

### 6.5 Simpler than Shapr3D: the concrete rules
- At most **7 tool groups** in the sidebar. Everything else lives in context menus.
- Every tool has **one** obvious default (extrude out = join, into the body = cut). Options sit behind a "⋯".
- Wording without CAD jargon ("Hollow out" instead of "Shell", with the CAD word as a small hint).
- Every input can be undone, and no dialog blocks the view.

### 6.6 Onboarding (5 interactive tutorials, each about 3 minutes)
1. **Keychain with your name**: sketch, extrude, text, fillet, export
2. **Phone stand**: dimensions, angles, mirror
3. **Box with a lid**: shell, fit tolerance, split body
4. **Wall hook with screw holes**: hole tool, chamfer, print check (overhang)
5. **Plant pot**: revolve, shell, pattern (drainage holes)

Each tutorial is a real document with step-by-step hints, and you can leave it at any time.

---

## 7. 3D printing module (PrintKit), the reason people will pick Formwerk

### 7.1 Export
- **3MF** (the default because it carries units, colours and multiple bodies; Bambu and Prusa prefer it)
- **STL** binary (works everywhere), one file or one per body
- **STEP** (for other CAD apps), **OBJ**, **USDZ** (AR Quick Look on iPad/iPhone)
- Quality slider: *Draft / Normal / Fine* (mesh tolerance 0.1 / 0.03 / 0.01 mm, angle 15° / 8° / 4°). It shows the triangle count and file size.
- Exported meshes are always **closed and correctly oriented** (we check before writing, see 7.2).

### 7.2 Print check (one tap, results shown on the model)
| Check | How | Display |
|---|---|---|
| Closed solid / manifold | B-rep check (`BRepCheck_Analyzer`) and mesh edge counting | red edges |
| Thin walls (< 0.8 mm, adjustable for the nozzle) | rays from each face inwards against the opposite face | heat map |
| Overhangs (> 45°, adjustable) | face normal vs. the build direction | orange faces + "rotate to fix?" |
| Tiny features (< nozzle diameter) | small edges and faces | marker |
| Too big for the printer | bounding box vs. bed preset | ghost outline of the bed |
| Floating parts | number of separate solids | list |

**"Auto-orient":** suggests the rotation with the fewest overhangs and the largest flat face on the bed.

### 7.3 Printer presets (bed size, nozzle)
Bambu Lab A1 mini / A1 / P1S / X1C / H2D · Prusa MK4S / Core One / MINI+ · Creality Ender-3 V3 / K1 · Elegoo Neptune 4 · Anycubic Kobra 3 · "Custom". This is a local JSON list, easy to extend.

### 7.4 Helpers
- **Filament estimate:** volume × (walls + infill estimate) × density (PLA 1.24 g/cm³, PETG 1.27, ABS 1.04, TPU 1.21) → grams and metres. Clearly labelled as an estimate (the slicer knows the real number).
- **Fit presets:** when two bodies should fit together: *Press fit 0.1 mm*, *Snug 0.2 mm*, *Loose 0.4 mm*. The gap gets applied automatically (offset face).
- **Hole compensation:** an optional +0.2 mm on holes, because printed holes come out smaller.
- **Text:** any installed font (CoreText → outlines → sketch), emboss or engrave, depth in mm.
- **Open in slicer:** share sheet / "Open in…" (Bambu Handy, Bambu Studio, PrusaSlicer, OrcaSlicer, Cura). On Mac: "Open with" + remember the favourite slicer.

---

## 8. Languages and units

- **15 languages** (same set as StockStart): de, fr, it, es, pt-BR, nl, tr, pl, ja, ko, zh-Hans, zh-Hant, hi, ar, id, plus English as the base.
- Xcode **String Catalog** (`Localizable.xcstrings`). No hard-coded text, and the build fails on missing translations (check script in `tools/`).
- **Arabic:** the UI mirrors (sidebar on the right, timeline right-to-left). The **3D view and the X/Y/Z axes do not mirror**, and numbers stay left-to-right.
- **German:** long words (e.g. "Verrundung", "Abmessungsbeschränkung"). Buttons must wrap or shrink, which gets checked on screenshots.
- **Japanese/Chinese:** check line height and font fallback.
- Decimal comma vs. dot follows the language (`12,5` in German, `12.5` in English). Both are always accepted as input.
- The tutorials and the App Store texts are translated too.

---

## 9. Money, privacy and the App Store

### 9.1 Money
- **Completely free, no ads.** Ads in a CAD app would kill concentration and reviews.
- Optional **"Support Formwerk"** in-app purchase (tip jar, 3 tiers, CHF 3 / 7 / 15, non-consumable "Supporter" badge in About). It unlocks **nothing**. All features stay free.
- Running costs: **CHF 0** (no servers). Only the Apple Developer Program, which is already paid.

### 9.2 Privacy
- No account, no tracking, no analytics SDK. App Store privacy label: **"Data Not Collected"**.
- Crash reports only through Apple's own system (opt-in by the user at OS level).
- No ATT prompt needed.

### 9.3 App Store
- **Universal Purchase:** one app record for iPad + Mac (same bundle ID, multiplatform).
- Category: **Graphics & Design**, secondary: **Productivity**. Age rating 4+.
- Keywords (no competitor names): `cad,3d,print,printer,stl,3mf,step,design,model,maker,sketch,pencil,parametric`
- Screenshots: iPad 13" + 11", Mac 2880×1800. Each one shows a real printable object (keychain, bracket, box, hook, pot).
- Review notes: "No login. The tutorials in the welcome screen show all features."
- TestFlight through the same team (HC67GN5D2X) and the same `deploy/deploy.sh` pattern as StockStart. Create the App Store Connect record **before** the first upload (StockStart lesson: "Error Downloading App Information").

---

## 10. Building it: phases and "done when"

Every phase ends with something you can try on the iPad. Each phase gets an entry in PROJECT-LOG.md.

| Phase | Content | Done when |
|---|---|---|
| **M0: kernel spike** (go/no-go) | `tools/build-occt.sh` builds OCCT as xcframeworks (iPad device, simulator, Mac arm64+x86_64). Swift calls OCCT: box − cylinder → fillet → mesh → STL. | An STL with a filleted hole opens correctly in PrusaSlicer. The app size is noted. **If OCCT doesn't work on iOS, stop and rethink before any UI.** |
| **M1: viewport** | Metal view, camera (orbit/pan/zoom), grid, view cube, face/edge picking, highlights | Imported STEP models can be turned smoothly and faces selected on iPad and Mac |
| **M2: sketching** | Sketch tools, solver, constraints, dimensions, region detection, snapping | A fully defined sketch (rectangle with holes and a slot, all dimensioned) turns black |
| **M3: solids** | Extrude/push-pull, revolve, booleans, fillet, chamfer, shell, hole, mirror, patterns, move gizmo, construction planes | The 5 tutorial objects can be modelled by hand |
| **M4: documents and history** | `.formwerk` format, timeline with editing, undo/redo, iCloud, thumbnails, templates | Change an early dimension → all 30 test models rebuild correctly. Close and reopen → identical |
| **M5: printing** | Export (3MF/STL/STEP/OBJ/USDZ), import, print check, bed presets, auto-orient, filament, fit presets, text | A box with a lid exported from the iPad prints on a Bambu/Prusa and the lid fits |
| **M6: Mac polish** | Menu bar, shortcuts, mouse presets, multiple windows, right-click | The same 5 objects can be modelled with mouse + keyboard alone |
| **M7: languages, accessibility, onboarding** | 15 languages, RTL, Dynamic Type in the panels, VoiceOver for menus, 5 tutorials | Screenshots in de/ar/ja show no cut-off text. A new tester prints their first part in < 10 min |
| **M8: beta and launch** | TestFlight with 10–20 makers, bug fixing, App Store texts in 15 languages, screenshots | No crash in 1 week of beta. Submitted to the App Store |

---

## 11. Testing

- **FormwerkModel / SketchKit:** unit tests (solver cases: every constraint type, over-defined sketches, dragging), with high coverage, since this is pure Swift.
- **KernelKit golden tests:** each operation on standard shapes, checked by **volume and area** with a tolerance (e.g. a 10 mm cube with a 1 mm fillet = known volume). Fast, exact, independent of the mesh.
- **Rebuild tests:** 30 models, early dimensions changed, references must stay correct (see 4.5).
- **Export round-trip:** export → import → same volume. STL/3MF additionally checked with the free PrusaSlicer CLI (`prusa-slicer --info`), which must show "manifold = yes".
- **Performance tests:** solver < 5 ms, rebuild of a 50-feature model < 1 s on an A12 iPad, 60 fps while orbiting.
- **UI tests:** main flow (sketch → extrude → export) on the iPad simulator and the Mac.
- **Real prints:** each milestone from M3 on ends with at least one real print.

---

## 12. Risks

| Risk | Likelihood | Impact | What we do |
|---|---|---|---|
| OCCT won't build/run cleanly on iPadOS | medium | high | M0 is a go/no-go spike **before** any UI. Fallback: Manifold (mesh-only, no fillets) for a reduced v1 |
| LGPL vs. App Store | low (with a plan) | high | Dynamic frameworks + open-source app (recommended) or relink kit. Open decision #1 |
| Topological naming breaks history | high | medium | Signatures + OCCT history + yellow warnings + 30-model test suite (4.5) |
| Pencil UX feels worse than Shapr3D | medium | high | Test early with real users. Spend M2 on the feel of snapping and dragging, not just features |
| Memory on older iPads | medium | medium | A12 minimum recommendation, coarse preview meshes, release the shape cache in the background |
| App size from OCCT | low | low | Only the needed toolkits (≈ 25–40 MB). Fine for a CAD app |
| Fillets fail on complex edges | medium | medium | Clear error message ("fillet too large for this edge, max ≈ 3.2 mm") instead of a crash. Suggest the largest working radius |
| Too much scope for one person + Claude | high | high | v1 list is fixed. Everything else is v1.1+. Section 3 "Never" is final |

---

## 12a. Money (decided 2026-10-28)
Free download + one-time Formwerk Pro (CHF 10, no subscription). Details and reasons: BUSINESS-PLAN.md and PROJECT-LOG 2026-10-28.

## 12b. Next version backlog
- **AI assistant, bring your own account:**
  - The user signs in with the AI service they choose (Claude, ChatGPT, Gemini, …) using their own key or account.
  - They describe a part ("wall hook for a 20 mm rail, 3 mm screw holes") and the AI builds it as normal, editable timeline steps (sketch, extrude, fillet…), never as a dead mesh.
  - **Why it fits the "no paid APIs" rule:** the user pays their own provider; Formwerk has no server and no cost. The key stays in the Keychain.
  - **To decide:**
    - which providers ship first
    - the feature format the AI writes: probably JSON for our `Feature` types, checked by ModelBuilder before it's applied
    - the App Store privacy label (data goes to a third party the user chose)

## 13. Open decisions (for you)

1. **Open source?** Make Formwerk's own code public on GitHub (MPL-2.0). This is the recommendation: it makes the LGPL rules easy, builds trust and costs nothing. Or a private repo + relink kit.
2. **Tip jar** in v1.0 or only later?
3. **Minimum iPad:** keep A12 (iPadOS 17) or start at M1 iPads (simpler, faster, but fewer users)?
4. **Name final?** Formwerk, or one of the alternatives?
5. **GitHub repo:** `Yves1gif/formwerk` (public if #1 = yes)?

---

## 14. Next step

**Start with M0**: build OCCT for iPad and Mac and model, fillet and export one box with a hole as STL from Swift. That decides whether the whole plan works. Only after that comes any UI.
