# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Room Capsule is an iOS app (SwiftUI + SwiftData), currently at the freshly-generated Xcode template stage. Paths contain spaces ("Room Capsule"), so always quote them in shell commands.

## Commands

Build for the simulator:

```sh
xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

Run the app in the simulator (after building):

```sh
xcrun simctl boot "iPhone 15 Pro"  # if not already booted
xcrun simctl install booted <path-to-built-.app>
xcrun simctl launch booted jp.hibiki.roomcapsule.Room-Capsule
```

There are no test targets yet. Once one exists, run tests with:

```sh
xcodebuild -project "Room Capsule.xcodeproj" -scheme "Room Capsule" \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' test
```

To run a single test, add `-only-testing:<TestTarget>/<TestClass>/<testMethod>`.

## Architecture

- `Room Capsule/Room_CapsuleApp.swift` — `@main` entry point. Creates the shared SwiftData `ModelContainer` (schema currently: `Item`) and injects it into the view hierarchy via `.modelContainer()`.
- `Room Capsule/Item.swift` — the sole `@Model` SwiftData class. New persistent models must be added to the `Schema([...])` in `Room_CapsuleApp.swift`.
- `Room Capsule/ContentView.swift` — root view; uses `@Query` to fetch models and `@Environment(\.modelContext)` for inserts/deletes. Previews use an in-memory model container.

Persistence is on-disk SwiftData (`isStoredInMemoryOnly: false`); there is no schema migration setup, so changing `@Model` properties can crash existing installs unless the app is reinstalled or a migration plan is added.


## Language rules
- Always answer in Japanese.

