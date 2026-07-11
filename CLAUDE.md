# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Room Capsule is an iOS app (SwiftUI + RealityKit + ARKit + RoomPlan + Metal) that scans rooms with RoomPlan and replays them as AR miniatures, full-scale AR, walk-in 3D views, 2D floor plans, high-quality USDZ models, and real Gaussian Splatting rendering. The shipped v1 exposed only scan / 3D preview / miniature AR (with a full-scale toggle) / Before-After timeline / 2D floor plan / USDZ share; after the v1 release, the remaining features (Gaussian Splatting, memo pins, furniture ghosts) were re-enabled via `FeatureFlags` (see Architecture), while the portal-AR feature was retired in favor of a direct "部屋の中に入る" walk-in view. Paths contain spaces ("Room Capsule"), so always quote them in shell commands.

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77): any file added under `Room Capsule/` is automatically part of the target — no pbxproj editing needed for new files.

## Commands

Build for the simulator:

```sh
xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build
```

(Always pass an explicit `OS=` — a bare device name sometimes fails to match on this machine.)

Run the app in the simulator (after building):

```sh
xcrun simctl boot "iPhone 17 Pro"  # if not already booted
# IMPORTANT: resolve the .app via -showBuildSettings (multiple DerivedData dirs exist;
# a bare `find` may pick a stale template build)
BUILT_DIR=$(xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  -showBuildSettings build 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | sed 's/.*= //')
xcrun simctl install booted "$BUILT_DIR/Room Capsule.app"
xcrun simctl launch booted jp.hibiki.roomcapsule -seedDemo
```

Debug launch arguments (all `#if DEBUG`-gated; simulator builds are Debug by default): `-seedDemo` (auto-add demo room when store is empty), `-autoPreview` (open the first capsule's 3D preview at launch — smoke-tests the RealityKit stack in the simulator), `-autoSplat` (generate/attach a sample .splat and open the Metal splat viewer — smoke-tests the Gaussian Splatting stack), `-autoSplatAR` (same but opens the Splat AR screen; shows the AR-unavailable fallback in the simulator), `-autoSplatCapture` (open the LiDAR splat-capture screen; LiDAR-unavailable fallback in the simulator), `-previewMode <rawValue>` (initial display mode for `-autoPreview`, e.g. `scanModel`), `-autoDetail` (push the first capsule's detail screen at launch), `-autoInside` (combined with `-autoDetail`: open the walk-in "部屋の中に入る" view from the detail screen), `-autoTimeline` (open the first capsule's Before/After timeline at launch), `-autoSettings` (open the settings sheet at launch).

There are no test targets yet. Once one exists, run tests with `xcodebuild ... test` and `-only-testing:<TestTarget>/<TestClass>/<testMethod>` for a single test.

## Architecture

- `FeatureFlags.swift` — release scope control: `static let` bools (`splat`, `memoPins`, `furnitureGhosts`) hide the UI entry points for those features while all implementation code stays compiled. All were `false` for the shipped v1 and are now all `true` (re-enabled post-v1, with the user-facing delete/settings strings restored to name the features). A `portal` flag existed until the portal-AR entry point was removed entirely (see Views). Pins/ghosts are also filtered out of rendering (`RoomEntityFactory.makeRoomEntity` and `FloorPlanCanvas`) while their flags are off. If a feature ever needs hiding again: flip the bool and re-generalize those strings.
- `Models/RoomModels.swift` — Codable value types: `RoomCapsule` (name + versions + memo pins + furniture ghosts), `RoomScanVersion`, `SimplifiedRoomGeometry` (walls/openings/furniture/floor as positioned boxes: position + rotationY + size), pins, ghosts. `SIMD3<Float>` is Codable as-is. File paths are stored **relative to Documents** (see `AppFiles`).
- `Models/SplatModels.swift` — `SplatAsset`, `SplatFileType` (.ply/.splat/.spz).
- `Services/RoomCapsuleStore.swift` — the single `ObservableObject` store (injected via `.environmentObject`). Persistence is JSON (`Documents/RoomCapsules/capsules.json`) + per-capsule file directories; **not** SwiftData. `capsules.json` is a versioned envelope `{schemaVersion, capsules}` (bare-array files from pre-release builds still decode via a fallback). When changing the schema: bump `currentSchemaVersion` and add a migration in `load()`; new persisted fields must be optional or custom-decoded — synthesized `Decodable` ignores property default values. All mutations go through store methods which persist immediately. Thumbnails are rendered from `FloorPlanCanvas` via `ImageRenderer`.
- `Services/CapturedRoomConverter.swift` — RoomPlan `CapturedRoom` → `SimplifiedRoomGeometry`. All rendering derives from the simplified geometry (never from RoomPlan meshes), so every screen works with demo data on the simulator. Coordinates stay in the scan's AR-session frame (arbitrary origin/yaw per scan); display centers via `horizontalCenter`, and `Services/RoomGeometryAlignment.swift` estimates the relative yaw between two scans of the same room (dominant wall direction + 4 quarter-turn candidates scored by wall/opening/furniture landmark matching — doors/windows break the 180° ambiguity) so `TimelineComparisonView` can overlay them. Its `uprightYaw(of:)` also axis-aligns (and prefers landscape) the 2D plan: `FloorPlanCanvas` rotates the geometry before drawing, which straightens both the floor-plan screen and newly rendered thumbnails; thumbnails saved before that fix stay tilted until re-scanned.
- `AR/RoomEntityFactory.swift` — builds the RealityKit entity tree for a room in a given `RoomDisplayMode` (model/scanModel/dimensions/xray/furnitureOnly/structureOnly/memo/photo/wireframe). `.scanModel` loads the RoomPlan-exported USDZ via `USDZModelCache` (load-once + clone; same session coordinates as the simplified geometry, so the standard content offset aligns it) and falls back to `.model` boxes if the file is missing; gate its availability with `RoomDisplayMode.availableModes(hasUSDZ:)`. Scan saving exports USDZ with `.model` option (furniture meshes) falling back to parametric. Custom components `RoomPartComponent` (tap → inspector info) and `BaseAppearanceComponent` (restores materials; `applyGlobalOpacity` drives the full-scale opacity slider and Before/After crossfade). Components are registered in `Room_CapsuleApp.init`.
- `AR/ARSupport.swift` — `ARCapabilities` (AR/RoomPlan availability; both false in simulator → fallback UIs), `Haptics`, `RoomSelectionManager` (shared tap-select + highlight), `GhostDragHelper` (shared drag-to-move for furniture ghosts: a pan that starts on a ghost moves it — ray/horizontal-plane intersection at the ghost's height, clamped to room bounds, persisted via `onGhostMoved` → `store.upsertGhost` on gesture end; pans starting elsewhere keep their original meaning: orbit in preview, room move in miniature).
- `Services/Splat*.swift` + `Shaders/GaussianSplat.metal` — real Gaussian Splatting rendering via Metal. `GaussianSplatLoader` parses .splat / 3DGS .ply (scale/rot/opacity/f_dc, plus `f_rest_*` higher-order SH packed channel-major as 45 Float16 per splat — degree-1/2 files are zero-padded) and precomputes 3D covariances on the CPU; the vertex shader evaluates SH 1–3 per splat using the model-space camera position from the inverted combined view matrix (so flips/scale are handled), adding to the baked-in DC color; the shared `SplatRenderCore` (pipeline/buffers/async 16-bit counting sort via `SplatDepthSorter`, re-sorted when the camera turns ~2.5° or moves) drives both `MetalSplatView` (orbit-camera viewer, `SplatMetalRenderer`) and `SplatARView` (AR: an `ARView` for camera feed/planes/gestures with a transparent MTKView overlaid; `SplatARRenderer` builds the combined view matrix from `ARFrame.camera` × model matrix — uniform scale flows through the covariance math, so the shader is shared). Plain PLYs without 3DGS attributes fall back to the SceneKit point cloud (`SplatPointCloudLoader`, which also hosts the shared `PLYHeader` parser). `SampleSplatFactory` procedurally generates a sample room .splat (also used by `-autoSplat`). `LiDARSplatAccumulator` + `SplatCaptureView` implement in-app capture (surfel-style) with a live preview (`LiveSplatPreviewRenderer`: a transparent MTKView over the capture ARView draws the accumulator's append-only preview arrays with identity model matrix — capture coords are world coords — using preallocated max-capacity buffers, new points appended to the tail of the active index buffer and a full background re-sort every ~30 frames): LiDAR sceneDepth pixels are unprojected via camera intrinsics (image coords → flip Y/Z → camera.transform), normals are estimated from right/down depth neighbors (discontinuity-guarded, camera-facing), colors are distance-weighted averages from the YCbCr capturedImage, all deduped on a 1 cm voxel grid (max 1M). Export prunes floaters (<2 of 26 voxel neighbors) and writes surface-aligned flattened gaussians (tangent σ = voxel, normal σ = 0.2×voxel; quaternion from +Z to the y/z-flipped normal) via `SplatImportService.attachSplatData` — no 3DGS training, so quality sits between the naive point splat and Scaniverse-style optimized splats. The renderer abstraction is `SplatRenderable` / `SplatRendererRegistry.active`.
- `Views/` — one file per screen. AR screens (`MiniatureARView`, `FullScaleARView`, `PortalARView`) each wrap an `ARView` in a `UIViewRepresentable` whose Coordinator owns placement/gestures and rebuilds the room entity when a content hash (geometry+pins+ghosts+mode+usdzURL) changes. `MiniatureARView` is the main AR entry: it has a miniature⇄full-scale toggle (animated scale around the placement anchor; pinch is disabled at full scale) plus an opacity slider shown only at full scale. `FullScaleARView`/`PortalARView` and the `DetailScreen.fullScale`/`.portal` cases are kept compiled but unreachable (full-scale superseded by that toggle; the portal door was retired because it degraded on large scans — its walk-in payoff is now the direct `DetailScreen.inside` mode-grid entry). `RoomImmersivePreviewView` is the non-AR orbit-camera fallback used everywhere (also the walk-in "部屋の中に入る" view with `startsInside: true`, which works in the simulator too).

## Gotchas

- Compiling `.metal` files requires the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — already installed on this machine (Xcode 26 ships without it).
- Build settings use `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`: every file must explicitly import what it uses (e.g. `import Combine` for `ObservableObject/@Published`, `import UIKit` for `UIColor`).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on; off-main work (e.g. `SplatPointCloudLoader`) is marked `nonisolated` and called through `Task.detached`.
- Deployment target is iOS 26.0 (the developer's devices run iOS 26; 26.0 rather than the template's 26.5 so any 26.x point release can install). Don't raise it to 26.5 without asking; lowering to 17.0 is known to compile cleanly if broader device support is ever needed.
- RoomPlan code must stay behind `#if canImport(RoomPlan)` with runtime `RoomCaptureSession.isSupported` checks; `RoomCaptureViewDelegate` requires NSCoding, hence the `UIViewController` host in `RoomCaptureScanView.swift`.
- The UI is dark-mode-only by design: `.preferredColorScheme(.dark)` on the root and on sheets, with `Theme` colors and white text hard-coded for dark. Don't remove those modifiers without first building an adaptive light palette.
- App metadata lives in pbxproj `INFOPLIST_KEY_*` build settings (no Info.plist file): display name "Room Capsule", App Store category lifestyle, iPhone portrait-only (iPad all orientations), Japanese camera/photo usage strings.
- Never break the demo-mode path: every visible feature must be reachable in the simulator via `DemoRoomFactory` data (seeded with `-seedDemo`); the Splat stacks are also smoke-testable directly via the `-autoSplat*` launch arguments.

## Language rules
- Always answer in Japanese.
- UI strings are Japanese.
