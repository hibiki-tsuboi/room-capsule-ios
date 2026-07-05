import SwiftUI
import PhotosUI
import UIKit
import simd

// MARK: - メモピン一覧

struct MemoPinListView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let capsuleID: UUID
    var preferredVersionID: UUID?

    @State private var editingPin: RoomMemoPin?
    @State private var creatingPin = false

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }

    var body: some View {
        NavigationStack {
            ZStack {
                CapsuleBackground()

                if let capsule {
                    if capsule.memoPins.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 48))
                                .foregroundStyle(Theme.accentGradient)
                            Text("まだメモがありません")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("部屋の中に小さな光るピンを浮かべて、\n傷の記録やお気に入りの場所をメモできます。")
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                            Button {
                                creatingPin = true
                            } label: {
                                Label("メモを追加", systemImage: "plus")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        }
                        .padding()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(capsule.memoPins.sorted(by: { $0.createdAt > $1.createdAt })) { pin in
                                    Button {
                                        editingPin = pin
                                    } label: {
                                        MemoPinRow(
                                            pin: pin,
                                            versionName: capsule.version(id: pin.versionID)?.name
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.deletePin(pinID: pin.id, in: capsuleID)
                                        } label: {
                                            Label("削除", systemImage: "trash")
                                        }
                                    }
                                }

                                Text("ヒント: 3Dプレビューの「ピン配置」モードで、空間の好きな場所に直接ピンを置くこともできます。")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.5))
                                    .padding(.top, 8)
                            }
                            .padding()
                        }
                    }
                }
            }
            .navigationTitle("メモピン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creatingPin = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(item: $editingPin) { pin in
            MemoPinEditorView(capsuleID: capsuleID, pin: pin)
        }
        .sheet(isPresented: $creatingPin) {
            MemoPinEditorView(
                capsuleID: capsuleID,
                versionID: preferredVersionID,
                initialPosition: defaultPosition()
            )
        }
    }

    /// 新規ピンの初期位置(部屋の中央・目の高さ)
    private func defaultPosition() -> SIMD3<Float> {
        guard let capsule,
              let geometry = (capsule.version(id: preferredVersionID) ?? capsule.latestVersion)?.simplifiedGeometry,
              !geometry.isEmpty else {
            return [0, 1.1, 0]
        }
        let center = geometry.horizontalCenter
        return [center.x, geometry.floorY + 1.1, center.y]
    }
}

struct MemoPinRow: View {
    let pin: RoomMemoPin
    var versionName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pin.category.symbolName)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(pin.category.color.opacity(0.7), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(pin.title.isEmpty ? pin.category.displayName : pin.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !pin.body.isEmpty {
                    Text(pin.body)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(pin.category.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pin.category.color.opacity(0.25), in: Capsule())
                        .foregroundStyle(pin.category.color)
                    Text(versionName ?? "全バージョン")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.45))
                    if !pin.photoPaths.isEmpty {
                        Label("\(pin.photoPaths.count)", systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
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
}

// MARK: - メモピン編集

struct MemoPinEditorView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss

    let capsuleID: UUID
    private let existingPin: RoomMemoPin?

    @State private var title: String
    @State private var bodyText: String
    @State private var category: MemoCategory
    @State private var versionID: UUID?
    @State private var posX: Float
    @State private var posY: Float
    @State private var posZ: Float
    @State private var photoPaths: [String]
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sessionAddedPhotoPaths: [String] = []
    @State private var removedExistingPhotoPaths: [String] = []
    @State private var saved = false
    @State private var showDeleteConfirm = false

    /// 既存ピンの編集
    init(capsuleID: UUID, pin: RoomMemoPin) {
        self.capsuleID = capsuleID
        self.existingPin = pin
        _title = State(initialValue: pin.title)
        _bodyText = State(initialValue: pin.body)
        _category = State(initialValue: pin.category)
        _versionID = State(initialValue: pin.versionID)
        _posX = State(initialValue: pin.position.x)
        _posY = State(initialValue: pin.position.y)
        _posZ = State(initialValue: pin.position.z)
        _photoPaths = State(initialValue: pin.photoPaths)
    }

    /// 新規ピンの作成
    init(capsuleID: UUID, versionID: UUID?, initialPosition: SIMD3<Float>) {
        self.capsuleID = capsuleID
        self.existingPin = nil
        _title = State(initialValue: "")
        _bodyText = State(initialValue: "")
        _category = State(initialValue: .viewing)
        _versionID = State(initialValue: versionID)
        _posX = State(initialValue: initialPosition.x)
        _posY = State(initialValue: initialPosition.y)
        _posZ = State(initialValue: initialPosition.z)
        _photoPaths = State(initialValue: [])
    }

    private var capsule: RoomCapsule? { store.capsule(id: capsuleID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("メモ") {
                    TextField("タイトル", text: $title)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 90)
                }

                Section("カテゴリ") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104))], spacing: 8) {
                        ForEach(MemoCategory.allCases) { item in
                            Button {
                                category = item
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: item.symbolName)
                                    Text(item.displayName)
                                }
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(
                                    category == item ? item.color.opacity(0.35) : Color.white.opacity(0.06),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(category == item ? item.color : .clear, lineWidth: 1)
                                )
                                .foregroundStyle(category == item ? item.color : .white)
                            }
                            .buttonStyle(.plain)
                        }
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

                Section("3D 空間での位置") {
                    positionSlider(label: "左右", value: $posX, range: bounds.x)
                    positionSlider(label: "高さ", value: $posY, range: bounds.y)
                    positionSlider(label: "前後", value: $posZ, range: bounds.z)
                }

                Section("写真") {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 3, matching: .images) {
                        Label("写真を追加", systemImage: "photo.badge.plus")
                    }
                    if !photoPaths.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(photoPaths, id: \.self) { path in
                                    photoThumbnail(path)
                                }
                            }
                        }
                    }
                }

                if existingPin != nil {
                    Section {
                        Button("このメモを削除", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundTop)
            .navigationTitle(existingPin == nil ? "メモを追加" : "メモを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog("このメモを削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let existingPin {
                        store.deletePin(pinID: existingPin.id, in: capsuleID)
                    }
                    saved = true
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let path = store.savePinPhoto(data, capsuleID: capsuleID) {
                            photoPaths.append(path)
                            sessionAddedPhotoPaths.append(path)
                        }
                    }
                    photoItems = []
                }
            }
            .onDisappear {
                // 保存せずに閉じた場合、このセッションで追加した写真ファイルを掃除する
                if !saved {
                    for path in sessionAddedPhotoPaths {
                        store.deleteFile(relativePath: path)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var bounds: (x: ClosedRange<Float>, y: ClosedRange<Float>, z: ClosedRange<Float>) {
        guard let capsule,
              let geometry = (capsule.version(id: versionID) ?? capsule.latestVersion)?.simplifiedGeometry,
              let horizontal = geometry.horizontalBounds else {
            return (-5...5, 0...3, -5...5)
        }
        let minY = geometry.floorY
        return (
            (horizontal.min.x - 1)...(horizontal.max.x + 1),
            minY...(minY + geometry.wallHeight + 0.5),
            (horizontal.min.y - 1)...(horizontal.max.y + 1)
        )
    }

    private func positionSlider(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
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

    @ViewBuilder
    private func photoThumbnail(_ path: String) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(contentsOfFile: AppFiles.url(forRelativePath: path).path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 76, height: 76)
            }
            Button {
                removePhoto(path)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
    }

    private func removePhoto(_ path: String) {
        photoPaths.removeAll { $0 == path }
        if sessionAddedPhotoPaths.contains(path) {
            sessionAddedPhotoPaths.removeAll { $0 == path }
            store.deleteFile(relativePath: path)
        } else {
            removedExistingPhotoPaths.append(path)
        }
    }

    private func save() {
        var pin = existingPin ?? RoomMemoPin(title: "", body: "", category: category, position: .zero)
        pin.title = title
        pin.body = bodyText
        pin.category = category
        pin.versionID = versionID
        pin.position = [posX, posY, posZ]
        pin.photoPaths = photoPaths
        store.upsertPin(pin, in: capsuleID)
        for path in removedExistingPhotoPaths {
            store.deleteFile(relativePath: path)
        }
        saved = true
        Haptics.success()
        dismiss()
    }
}
