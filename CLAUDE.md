# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Room Capsule is an iOS app (SwiftUI + RealityKit + ARKit + RoomPlan + Metal) that scans rooms with RoomPlan and replays them as AR miniatures, full-scale AR, portals, 2D floor plans, high-quality USDZ models, and real Gaussian Splatting rendering. Paths contain spaces ("Room Capsule"), so always quote them in shell commands.

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
xcrun simctl launch booted jp.hibiki.roomcapsule.Room-Capsule -seedDemo
```

Debug launch arguments: `-seedDemo` (auto-add demo room when store is empty), `-autoPreview` (open the first capsule's 3D preview at launch — smoke-tests the RealityKit stack in the simulator), `-autoSplat` (generate/attach a sample .splat and open the Metal splat viewer — smoke-tests the Gaussian Splatting stack), `-autoSplatAR` (same but opens the Splat AR screen; shows the AR-unavailable fallback in the simulator), `-autoSplatCapture` (open the LiDAR splat-capture screen; LiDAR-unavailable fallback in the simulator), `-previewMode <rawValue>` (initial display mode for `-autoPreview`, e.g. `scanModel`), `-autoDetail` (push the first capsule's detail screen at launch).

There are no test targets yet. Once one exists, run tests with `xcodebuild ... test` and `-only-testing:<TestTarget>/<TestClass>/<testMethod>` for a single test.

## Architecture

- `Models/RoomModels.swift` — Codable value types: `RoomCapsule` (name + versions + memo pins + furniture ghosts), `RoomScanVersion`, `SimplifiedRoomGeometry` (walls/openings/furniture/floor as positioned boxes: position + rotationY + size), pins, ghosts. `SIMD3<Float>` is Codable as-is. File paths are stored **relative to Documents** (see `AppFiles`).
- `Models/SplatModels.swift` — `SplatAsset`, `SplatFileType` (.ply/.splat/.spz).
- `Services/RoomCapsuleStore.swift` — the single `ObservableObject` store (injected via `.environmentObject`). Persistence is JSON (`Documents/RoomCapsules/capsules.json`) + per-capsule file directories; **not** SwiftData. All mutations go through store methods which persist immediately. Thumbnails are rendered from `FloorPlanCanvas` via `ImageRenderer`.
- `Services/CapturedRoomConverter.swift` — RoomPlan `CapturedRoom` → `SimplifiedRoomGeometry`. All rendering derives from the simplified geometry (never from RoomPlan meshes), so every screen works with demo data on the simulator.
- `AR/RoomEntityFactory.swift` — builds the RealityKit entity tree for a room in a given `RoomDisplayMode` (model/scanModel/dimensions/xray/furnitureOnly/structureOnly/memo/photo/wireframe). `.scanModel` loads the RoomPlan-exported USDZ via `USDZModelCache` (load-once + clone; same session coordinates as the simplified geometry, so the standard content offset aligns it) and falls back to `.model` boxes if the file is missing; gate its availability with `RoomDisplayMode.availableModes(hasUSDZ:)`. Scan saving exports USDZ with `.model` option (furniture meshes) falling back to parametric. Custom components `RoomPartComponent` (tap → inspector info) and `BaseAppearanceComponent` (restores materials; `applyGlobalOpacity` drives the full-scale opacity slider and Before/After crossfade). Components are registered in `Room_CapsuleApp.init`.
- `AR/ARSupport.swift` — `ARCapabilities` (AR/RoomPlan availability; both false in simulator → fallback UIs), `Haptics`, `RoomSelectionManager` (shared tap-select + highlight), `GhostDragHelper` (shared drag-to-move for furniture ghosts: a pan that starts on a ghost moves it — ray/horizontal-plane intersection at the ghost's height, clamped to room bounds, persisted via `onGhostMoved` → `store.upsertGhost` on gesture end; pans starting elsewhere keep their original meaning: orbit in preview, room move in miniature).
- `Services/Splat*.swift` + `Shaders/GaussianSplat.metal` — real Gaussian Splatting rendering via Metal. `GaussianSplatLoader` parses .splat / 3DGS .ply (scale/rot/opacity/f_dc) and precomputes 3D covariances on the CPU; the shared `SplatRenderCore` (pipeline/buffers/async 16-bit counting sort via `SplatDepthSorter`, re-sorted when the camera turns ~2.5° or moves) drives both `MetalSplatView` (orbit-camera viewer, `SplatMetalRenderer`) and `SplatARView` (AR: an `ARView` for camera feed/planes/gestures with a transparent MTKView overlaid; `SplatARRenderer` builds the combined view matrix from `ARFrame.camera` × model matrix — uniform scale flows through the covariance math, so the shader is shared). Plain PLYs without 3DGS attributes fall back to the SceneKit point cloud (`SplatPointCloudLoader`, which also hosts the shared `PLYHeader` parser). `SampleSplatFactory` procedurally generates a sample room .splat (also used by `-autoSplat`). `LiDARSplatAccumulator` + `SplatCaptureView` implement in-app capture: LiDAR sceneDepth pixels are unprojected via camera intrinsics (image coords → flip Y/Z → camera.transform), colored from the YCbCr capturedImage, deduped on a 2 cm voxel grid (max 600k), and written as isotropic gaussians through `SplatImportService.attachSplatData` — no 3DGS training, so quality is below Scaniverse-style optimized splats by design. The renderer abstraction is `SplatRenderable` / `SplatRendererRegistry.active`.
- `Views/` — one file per screen. AR screens (`MiniatureARView`, `FullScaleARView`, `PortalARView`) each wrap an `ARView` in a `UIViewRepresentable` whose Coordinator owns placement/gestures and rebuilds the room entity when a content hash (geometry+pins+ghosts+mode+usdzURL) changes. `RoomImmersivePreviewView` is the non-AR orbit-camera fallback used everywhere (also as the portal "inside" view with `startsInside: true`).

## Gotchas

- Compiling `.metal` files requires the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) — already installed on this machine (Xcode 26 ships without it).
- Build settings use `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`: every file must explicitly import what it uses (e.g. `import Combine` for `ObservableObject/@Published`, `import UIKit` for `UIColor`).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on; off-main work (e.g. `SplatPointCloudLoader`) is marked `nonisolated` and called through `Task.detached`.
- Deployment target is iOS 26.0 (the developer's devices run iOS 26; 26.0 rather than the template's 26.5 so any 26.x point release can install). Don't raise it to 26.5 without asking; lowering to 17.0 is known to compile cleanly if broader device support is ever needed.
- RoomPlan code must stay behind `#if canImport(RoomPlan)` with runtime `RoomCaptureSession.isSupported` checks; `RoomCaptureViewDelegate` requires NSCoding, hence the `UIViewController` host in `RoomCaptureScanView.swift`.
- Never break the demo-mode path: every feature must be reachable in the simulator via `DemoRoomFactory` data.

## Language rules
- Always answer in Japanese.
- UI strings are Japanese.
