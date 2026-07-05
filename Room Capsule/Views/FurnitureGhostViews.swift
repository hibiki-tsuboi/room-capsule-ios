import SwiftUI
import UIKit
import simd

// MARK: - 家具ゴースト一覧

struct FurnitureGhostListView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    var preferredVersionID: UUID?

    @State private var editingGhost: FurnitureGhost?
    @State private var showTypePicker = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }

    var body: some View {
        NavigationStack {
            ZStack {
                CapsuleBackground()

                if let capsule {
                    if capsule.furnitureGhosts.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "sofa.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.accentGradient)
                            Text("家具ゴーストがいません")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("「ここにベッドを置いたらどうなる?」を\n半透明のゴースト家具で試せます。")
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                            Button {
                                showTypePicker = true
                            } label: {
                                Label("ゴーストを追加", systemImage: "plus")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        .padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(capsule.furnitureGhosts) { ghost in
                                    Button {
                                        editingGhost = ghost
                                    } label: {
                                        ghostRow(ghost, capsule: capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.deleteGhost(ghostID: ghost.id, in: capsuleID)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                                }
                                Text("ゴーストはミニチュア AR・実寸 AR・3D プレビューで淡く光って表示されます。画面の中でゴーストを指で掴んでドラッグすると移動でき、位置は自動保存されます。")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.5))
                                    .padding(.top, 8)
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("家具ゴースト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showTypePicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showTypePicker) {
            GhostTypePickerView { type in
                let ghost = makeGhost(type: type)
                store.upsertGhost(ghost, in: capsuleID)
                showTypePicker = false
                editingGhost = ghost
            }
        }
        .sheet(item: $editingGhost) { ghost in
            FurnitureGhostEditorView(capsuleID: capsuleID, ghost: ghost)
        }
    }

    private func ghostRow(_ ghost: FurnitureGhost, capsule: RoomCapsule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ghost.type.symbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(ghost.type.color.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(ghost.name.isEmpty ? ghost.type.displayName : ghost.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(String(format: "%.1f × %.1f × %.1f m", ghost.size.x, ghost.size.y, ghost.size.z))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(capsule.version(id: ghost.versionID)?.name ?? "全バージョン")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.35))
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }

    /// 部屋の中央・床の上に新しいゴーストを置く
    private func makeGhost(type: FurnitureGhostType) -> FurnitureGhost {
        var position = SIMD3<Float>(0, type.defaultSize.y / 2, 0)
        if let geometry = (capsule?.version(id: preferredVersionID) ?? capsule?.latestVersion)?.simplifiedGeometry,
           !geometry.isEmpty {
            let center = geometry.horizontalCenter
            position = [center.x, geometry.floorY + type.defaultSize.y / 2, center.y]
        }
        return FurnitureGhost(
            type: type,
            name: "",
            position: position,
            rotationY: 0,
            size: type.defaultSize,
            versionID: preferredVersionID
        )
    }
}

// MARK: - ゴーストの種類選択

struct GhostTypePickerView: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: (FurnitureGhostType) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                CapsuleBackground()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(FurnitureGhostType.allCases) { type in
                            Button {
                                Haptics.light()
                                onSelect(type)
                            } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: type.symbolName)
                                        .font(.title)
                                        .foregroundStyle(type.color)
                                    Text(type.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                    Text(String(format: "%.1f × %.1f m", type.defaultSize.x, type.defaultSize.z))
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .glassCard(cornerRadius: 18)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("家具を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - ゴースト編集

struct FurnitureGhostEditorView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss

    let capsuleID: UUID
    private let originalGhost: FurnitureGhost

    @State private var name: String
    @State private var width: Float
    @State private var height: Float
    @State private var depth: Float
    @State private var posX: Float
    @State private var posZ: Float
    @State private var lift: Float
    @State private var rotationDegrees: Float
    @State private var versionID: UUID?
    @State private var showDeleteConfirm = false

    init(capsuleID: UUID, ghost: FurnitureGhost) {
        self.capsuleID = capsuleID
        self.originalGhost = ghost
        _name = State(initialValue: ghost.name)
        _width = State(initialValue: ghost.size.x)
        _height = State(initialValue: ghost.size.y)
        _depth = State(initialValue: ghost.size.z)
        _posX = State(initialValue: ghost.position.x)
        _posZ = State(initialValue: ghost.position.z)
        _lift = State(initialValue: 0)
        _rotationDegrees = State(initialValue: ghost.rotationY * 180 / .pi)
        _versionID = State(initialValue: ghost.versionID)
    }

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }
    private var geometry: SimplifiedRoomGeometry? {
        (capsule?.version(id: versionID) ?? capsule?.latestVersion)?.simplifiedGeometry
    }

    private var currentGhost: FurnitureGhost {
        var ghost = originalGhost
        ghost.name = name
        ghost.size = [width, height, depth]
        ghost.position = [posX, floorY + height / 2 + lift, posZ]
        ghost.rotationY = rotationDegrees * .pi / 180
        ghost.versionID = versionID
        return ghost
    }

    private var floorY: Float { geometry?.floorY ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    HStack {
                        Image(systemName: originalGhost.type.symbolName)
                            .foregroundStyle(originalGhost.type.color)
                        TextField(originalGhost.type.displayName, text: $name)
                    }
                }

                Section("間取りプレビュー") {
                    if let geometry {
                        FloorPlanCanvas(
                            geometry: geometry,
                            pins: [],
                            ghosts: [currentGhost],
                            showDimensions: false,
                            showLabels: true
                        )
                        .frame(height: 180)
                        .background(Theme.backgroundTop, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Section("サイズ") {
                    ghostSlider(label: "幅", value: $width, range: 0.2...3.0)
                    ghostSlider(label: "高さ", value: $height, range: 0.2...2.4)
                    ghostSlider(label: "奥行", value: $depth, range: 0.2...3.0)
                }

                Section("位置と向き") {
                    ghostSlider(label: "左右", value: $posX, range: horizontalRangeX)
                    ghostSlider(label: "前後", value: $posZ, range: horizontalRangeZ)
                    ghostSlider(label: "浮かせる", value: $lift, range: 0...1.5)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("回転")
                            Spacer()
                            Text(String(format: "%.0f°", rotationDegrees))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $rotationDegrees, in: 0...360)
                            .tint(Theme.accentCyan)
                    }
                }

                Section("表示するバージョン") {
                    Picker("バージョン", selection: $versionID) {
                        Text("すべてのバージョン").tag(UUID?.none)
                        ForEach(capsule?.versions ?? []) { version in
                            Text(version.name).tag(Optional(version.id))
                        }
                    }
                }

                Section {
                    Button("このゴーストを削除", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundTop)
            .navigationTitle("家具ゴースト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.upsertGhost(currentGhost, in: capsuleID)
                        Haptics.success()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("このゴーストを削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    store.deleteGhost(ghostID: originalGhost.id, in: capsuleID)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // 既存の「浮かせ」量を復元
            lift = max(0, originalGhost.position.y - floorY - originalGhost.size.y / 2)
        }
    }

    private var horizontalRangeX: ClosedRange<Float> {
        guard let bounds = geometry?.horizontalBounds else { return -5...5 }
        return (bounds.min.x - 0.5)...(bounds.max.x + 0.5)
    }

    private var horizontalRangeZ: ClosedRange<Float> {
        guard let bounds = geometry?.horizontalBounds else { return -5...5 }
        return (bounds.min.y - 0.5)...(bounds.max.y + 0.5)
    }

    private func ghostSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f m", value.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(Theme.accentCyan)
        }
    }
}
