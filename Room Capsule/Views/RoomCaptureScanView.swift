import SwiftUI
import Combine
import UIKit
#if canImport(RoomPlan)
import RoomPlan
#endif

// MARK: - スキャン画面のエントリポイント

/// RoomPlan 対応端末ではスキャン UI を、非対応環境ではデモモード誘導を出す
struct RoomCaptureScanView: View {
    /// nil の場合は新しいカプセルを作る。指定時は既存カプセルへバージョン追加。
    let targetCapsuleID: UUID?

    var body: some View {
        #if canImport(RoomPlan)
        if ARCapabilities.isRoomPlanSupported {
            SupportedScanView(targetCapsuleID: targetCapsuleID)
        } else {
            RoomPlanUnavailableView()
        }
        #else
        RoomPlanUnavailableView()
        #endif
    }
}

// MARK: - RoomPlan 非対応フォールバック

struct RoomPlanUnavailableView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CapsuleBackground()

            VStack(spacing: 18) {
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accentGradient)
                Text("この iPhone では RoomPlan が使えません")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("部屋のスキャンには LiDAR センサー搭載の iPhone / iPad(Pro 系)と iOS 16 以降が必要です。\nデモ部屋なら、この端末でもすべての機能を体験できます。")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Button {
                    _ = store.addDemoCapsule()
                    Haptics.success()
                    dismiss()
                } label: {
                    Label("デモモードで体験する", systemImage: "wand.and.stars")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("閉じる") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(26)
            .glassCard(cornerRadius: 26)
            .padding(24)
        }
    }
}

#if canImport(RoomPlan)

// MARK: - スキャンセッションの状態

@MainActor
final class ScanSessionModel: ObservableObject {
    enum Phase {
        case scanning
        case processing
        case finished(CapturedRoom)
        case failed(String)
    }

    @Published var phase: Phase = .scanning
    @Published var wallCount = 0
    @Published var doorCount = 0
    @Published var windowCount = 0
    @Published var objectCount = 0

    weak var controller: RoomCaptureHostController?

    func finishScan() {
        phase = .processing
        controller?.finishSession()
    }

    func cancelScan() {
        controller?.cancelSession()
    }

    func liveUpdate(room: CapturedRoom) {
        wallCount = room.walls.count
        doorCount = room.doors.count
        windowCount = room.windows.count
        objectCount = room.objects.count
    }

    func processed(_ result: Result<CapturedRoom, Error>) {
        switch result {
        case .success(let room):
            phase = .finished(room)
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - スキャン UI 本体

struct SupportedScanView: View {
    @EnvironmentObject private var store: RoomCapsuleStore
    @Environment(\.dismiss) private var dismiss
    let targetCapsuleID: UUID?

    @StateObject private var model = ScanSessionModel()
    @State private var roomName = ""
    @State private var versionName = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?

    var body: some View {
        ZStack {
            RoomCaptureRepresentable(model: model)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iPhone をゆっくり動かして、部屋全体を映してください")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                        HStack(spacing: 10) {
                            scanStat("square.split.bottomrightquarter", "壁 \(model.wallCount)")
                            scanStat("door.left.hand.open", "ドア \(model.doorCount)")
                            scanStat("window.casement", "窓 \(model.windowCount)")
                            scanStat("sofa", "家具 \(model.objectCount)")
                        }
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 14)

                    Spacer()

                    CloseButton {
                        model.cancelScan()
                        dismiss()
                    }
                }
                .padding()

                Spacer()

                bottomArea
                    .padding(.bottom, 20)
            }
        }
        .alert("保存に失敗しました", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private func scanStat(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Theme.accentCyan)
    }

    @ViewBuilder
    private var bottomArea: some View {
        switch model.phase {
        case .scanning:
            Button {
                model.finishScan()
                Haptics.medium()
            } label: {
                Label("スキャン完了", systemImage: "checkmark")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(PrimaryButtonStyle())

        case .processing:
            ProgressView("スキャン結果を処理中…")
                .tint(Theme.accentCyan)
                .foregroundStyle(.white)
                .padding(16)
                .glassCard(cornerRadius: 16)

        case .finished(let room):
            savePanel(room)

        case .failed(let message):
            VStack(spacing: 12) {
                Text("スキャンに失敗しました")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                Button("閉じる") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(16)
            .glassCard(cornerRadius: 18)
            .padding(.horizontal)
        }
    }

    private func savePanel(_ room: CapturedRoom) -> some View {
        VStack(spacing: 14) {
            Label("部屋をカプセルに保存", systemImage: "cube.transparent")
                .font(.headline)
                .foregroundStyle(.white)

            if targetCapsuleID == nil {
                TextField("部屋の名前(例: 自分の部屋)", text: $roomName)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("バージョン名(例: 入居前)", text: $versionName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("破棄") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button {
                    save(room)
                } label: {
                    Label(isSaving ? "保存中…" : "保存する", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
        .padding(.horizontal)
    }

    private func save(_ room: CapturedRoom) {
        guard !isSaving else { return }
        isSaving = true
        var createdCapsuleID: UUID?

        do {
            let capsuleID: UUID
            if let targetCapsuleID {
                capsuleID = targetCapsuleID
            } else {
                let capsule = try store.createCapsule(named: roomName.isEmpty ? "スキャンした部屋" : roomName)
                capsuleID = capsule.id
                createdCapsuleID = capsule.id
            }

            let geometry = CapturedRoomConverter.simplifiedGeometry(from: room)

            // RoomPlan の生データ(JSON)と USDZ を可能な範囲で保存する。
            // USDZ は家具の形状モデル付き(.model)を優先し、失敗したら既定の
            // パラメトリック出力へフォールバックする(高品質モードの見た目が良くなる)。
            let capturedRoomJSON = try JSONEncoder().encode(room)
            var usdzTempURL: URL? = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).usdz")
            if let url = usdzTempURL {
                do {
                    try room.export(to: url, exportOptions: .model)
                } catch {
                    do {
                        try room.export(to: url)
                    } catch {
                        usdzTempURL = nil
                    }
                }
            }

            try store.addScannedVersion(
                versionName: versionName,
                geometry: geometry,
                capturedRoomJSON: capturedRoomJSON,
                usdzTempURL: usdzTempURL,
                to: capsuleID
            )
            Haptics.success()
            dismiss()
        } catch {
            if let createdCapsuleID {
                store.delete(capsuleID: createdCapsuleID)
            }
            isSaving = false
            saveErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - RoomCaptureView のラッパー

struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let model: ScanSessionModel

    func makeUIViewController(context: Context) -> RoomCaptureHostController {
        let controller = RoomCaptureHostController()
        controller.onLiveUpdate = { [weak model] room in
            model?.liveUpdate(room: room)
        }
        controller.onProcessed = { [weak model] result in
            model?.processed(result)
        }
        model.controller = controller
        return controller
    }

    func updateUIViewController(_ uiViewController: RoomCaptureHostController, context: Context) {}
}

/// RoomCaptureView をホストする UIViewController。
/// RoomCaptureViewDelegate は NSCoding 準拠が必要なため UIViewController で実装する。
final class RoomCaptureHostController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    private var captureView: RoomCaptureView!
    var onLiveUpdate: ((CapturedRoom) -> Void)?
    var onProcessed: ((Result<CapturedRoom, Error>) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        captureView.captureSession.delegate = self
        view.addSubview(captureView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        captureView.captureSession.run(configuration: configuration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureView.captureSession.stop()
    }

    /// 「スキャン完了」→ 停止すると didPresent で処理済み結果が返る
    func finishSession() {
        captureView.captureSession.stop()
    }

    func cancelSession() {
        onProcessed = nil
        captureView.captureSession.stop()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            onProcessed?(.failure(error))
        } else {
            onProcessed?(.success(processedResult))
        }
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        onLiveUpdate?(room)
    }
}

#endif
