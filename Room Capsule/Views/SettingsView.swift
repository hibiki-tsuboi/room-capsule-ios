import SwiftUI

/// 設定・プライバシー説明画面
struct SettingsView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false

    /// 例: "1.0.0 (1)"。ハードコードせず Info.plist の値を表示する
    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("このアプリについて") {
                    Text("Room Capsule は、いま目の前にある部屋を iPhone でスキャンして、ミニチュアや実寸の AR・2D の間取り図として保存し、あとから再体験できるアプリです。")
                        .font(.subheadline)
                }

                Section("プライバシーとデータ") {
                    Label {
                        Text("部屋のスキャンデータは、あなたの生活空間そのものであるプライベートな情報です。")
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Theme.accentCyan)
                    }
                    .font(.subheadline)

                    Label {
                        Text("このアプリは保存したデータをすべてこの iPhone の中(ローカル)にのみ保存します。クラウドへの送信は行いません。")
                    } icon: {
                        Image(systemName: "iphone")
                            .foregroundStyle(Theme.accentCyan)
                    }
                    .font(.subheadline)

                    Label {
                        Text("各部屋の削除ボタン、または下の「すべてのデータを削除」で、関連ファイルごと完全に削除できます。")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.accentCyan)
                    }
                    .font(.subheadline)
                }

                Section("データ") {
                    LabeledContent("保存済みの部屋", value: "\(store.capsules.count)")
                    Button("すべてのデータを削除", role: .destructive) {
                        confirmDeleteAll = true
                    }
                }

                Section("情報") {
                    LabeledContent("バージョン", value: appVersionText)
                }

                #if DEBUG
                Section {
                    Button {
                        _ = store.addDemoCapsule()
                        Haptics.success()
                    } label: {
                        Label("デモ部屋を追加", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("開発用(DEBUG ビルドのみ)")
                } footer: {
                    Text("テスト用にデモ部屋を追加します。このセクションは DEBUG ビルドにだけ表示されます。")
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundTop)
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog("すべてのデータを削除しますか?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("完全に削除", role: .destructive) {
                    store.deleteAllData()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("すべての部屋カプセルとスキャンデータがこの iPhone から完全に削除されます。この操作は取り消せません。")
            }
        }
        .preferredColorScheme(.dark)
    }
}
