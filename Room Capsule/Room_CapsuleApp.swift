//
//  Room_CapsuleApp.swift
//  Room Capsule
//
//  Created by Hibiki Tsuboi on 2026/07/05.
//

import SwiftUI

@main
struct Room_CapsuleApp: App {
    @StateObject private var store: RoomCapsuleStore

    init() {
        // カスタムコンポーネントは Entity 生成前に登録が必要
        RoomEntityFactory.registerComponents()
        _store = StateObject(wrappedValue: RoomCapsuleStore())
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accentCyan)
        }
    }
}
