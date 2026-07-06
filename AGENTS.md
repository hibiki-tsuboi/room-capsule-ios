# Repository Guidelines

## Project Structure & Module Organization

Room Capsule is a SwiftUI/RealityKit/ARKit/RoomPlan/Metal iOS app. Under `Room Capsule/`, keep models in `Models/`, persistence/import/rendering in `Services/`, shared RealityKit/AR code in `AR/`, screens in `Views/`, shaders in `Shaders/`, and assets in `Assets.xcassets/`. `PBXFileSystemSynchronizedRootGroup` picks up new files automatically. Quote paths with spaces, including `"Room Capsule.xcodeproj"` and `"Room Capsule/"`.

Rendering is centered on `SimplifiedRoomGeometry`. `RoomCapsuleStore` persists JSON plus per-capsule files under Documents; no SwiftData.

## Build, Test, and Development Commands

- `xcodebuild -downloadComponent MetalToolchain`: installs the Metal compiler if `.metal` builds fail.
- `xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build`: simulator build; keep explicit `OS=`.
- `xcrun simctl boot "iPhone 17 Pro"`: boot before install. Resolve `BUILT_PRODUCTS_DIR` with `xcodebuild ... -showBuildSettings`; broad `find` may pick stale products.
- `xcrun simctl launch booted jp.hibiki.roomcapsule -seedDemo`: launches with demo data.
- Useful launch arguments include `-seedDemo`, `-autoPreview`, `-autoSplat*`, `-autoSplatCapture`, `-autoDetail`, and `-previewMode scanModel`.

There are no test targets yet. When one is added, use `xcodebuild ... test`; add `-only-testing:...` for focused runs.

## Coding Style & Naming Conventions

Use four-space indentation and Swift casing: `UpperCamelCase` types, `lowerCamelCase` members. Prefer one screen per `Views/*.swift` file and keep shared behavior in `Services/` or `AR/`. Import frameworks explicitly; upcoming member import visibility is enabled. Default actor isolation is `MainActor`; mark heavy off-main helpers `nonisolated` and call them from `Task.detached` when appropriate. UI copy is Japanese, and the app is dark-mode-only.

Keep RoomPlan code behind `#if canImport(RoomPlan)` and runtime checks such as `RoomCaptureSession.isSupported`. Register custom RealityKit components before entity creation.

## Testing Guidelines

Preserve simulator demo-mode coverage for every feature path; AR and RoomPlan are unavailable there and must show fallback UIs. Smoke-test broad changes with `-seedDemo`, `-autoPreview`, and relevant Splat arguments. RoomPlan, LiDAR capture, AR placement, photo-library permissions, and USDZ export need physical-device checks. If XCTest targets are introduced, use names like `RoomCapsuleStoreTests.swift` and `testCreatesDemoCapsule()`.

## Commit & Pull Request Guidelines

Recent history uses gitmoji plus concise Japanese summaries, for example `✨ LiDAR スプラットスキャンにライブプレビューを追加`. Keep commits focused. PRs should include a summary, validation commands or device checks, affected simulator/device/OS, and screenshots or recordings for UI/AR changes.

## Security & Configuration Tips

App data is local under Documents; avoid cloud upload, analytics, or login. App metadata and privacy strings live in `Room Capsule.xcodeproj/project.pbxproj`, not an `Info.plist`. The deployment target is iOS 26.0; do not raise it without asking. Never break `DemoRoomFactory`.
