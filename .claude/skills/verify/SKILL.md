---
name: verify
description: Build, launch, and observe Room Capsule in the iOS simulator to verify a change end-to-end.
---

# Verifying Room Capsule changes

Surface is the simulator UI. There is no tap-injection tool on this machine
(no idb/cliclick; osascript lacks accessibility permission), so drive screens
via the `#if DEBUG` auto-launch arguments and capture screenshots.

## Recipe (all commands from the repo root; quote paths — they contain spaces)

```sh
# 1. Build
xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' build

# 2. Install + relaunch (resolve the .app via -showBuildSettings, never bare find)
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null
BUILT_DIR=$(xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  -showBuildSettings build 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | sed 's/.*= //')
xcrun simctl install booted "$BUILT_DIR/Room Capsule.app"
xcrun simctl terminate booted jp.hibiki.roomcapsule 2>/dev/null
xcrun simctl launch booted jp.hibiki.roomcapsule -seedDemo <auto-args for the screen under test>

# 3. Observe (wait a few seconds for animations to settle)
sleep 5 && xcrun simctl io booted screenshot out.png
```

## Reaching screens

Always pass `-seedDemo`. Then pick from the `#if DEBUG` args (full list in
CLAUDE.md): `-autoPreview` (+ `-previewMode <rawValue>`), `-autoDetail`,
`-autoDetail -autoInside` (walk-in view), `-autoTimeline`, `-autoSettings`,
`-autoSplat`, `-autoSplatAR`, `-autoSplatCapture`.

If a new screen has no arg, add one following the existing pattern
(`ProcessInfo.processInfo.arguments.contains("-autoX")` inside `#if DEBUG`
in the owning view's `.onAppear`) and document it in CLAUDE.md — that is the
project's established smoke-test convention, not test code.

## Gotchas

- AR screens show their fallback UI in the simulator — that fallback *is* the
  expected simulator behavior, not a failure.
- The walk-in view (`startsInside: true`, photo mode) opens facing the largest
  furniture piece with a wide-angle (85°) camera; with no furniture it faces
  straight ahead and may show a blank wall. Two identical screenshots a minute
  apart = settled state, not a stuck intro fade.
- Multiple DerivedData dirs exist; a stale template build will launch if you
  locate the .app with `find`.
