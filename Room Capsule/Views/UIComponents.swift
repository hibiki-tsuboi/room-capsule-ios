import SwiftUI

// MARK: - テーマ

enum Theme {
    static let backgroundTop = Color(red: 0.05, green: 0.06, blue: 0.13)
    static let backgroundBottom = Color(red: 0.10, green: 0.11, blue: 0.22)
    static let accentCyan = Color(red: 0.42, green: 0.87, blue: 0.95)
    static let accentPurple = Color(red: 0.64, green: 0.48, blue: 0.98)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentCyan, accentPurple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 背景

/// ダークなグラデーション + ぼんやり光るオーブの共通背景
struct CapsuleBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.backgroundTop, Theme.backgroundBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Theme.accentPurple.opacity(0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: -140, y: -260)
            Circle()
                .fill(Theme.accentCyan.opacity(0.13))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: 160, y: 300)
        }
        .ignoresSafeArea()
    }
}

// MARK: - ガラスカード

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            // 明るい 3D 背景(部屋の壁など)の上でも白飛びしないよう黒の下地を敷く
            .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - ボタンスタイル

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(Theme.accentGradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - 小物

struct StatBadge: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.75))
    }
}

struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
                .background(Color.black.opacity(0.32), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - 表示モード切替チップ

struct ModeChipsBar: View {
    var modes: [RoomDisplayMode] = RoomDisplayMode.allCases
    @Binding var selection: RoomDisplayMode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(modes) { mode in
                    Button {
                        selection = mode
                        Haptics.light()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.symbolName)
                            Text(mode.displayName)
                        }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selection == mode
                                ? AnyShapeStyle(Theme.accentGradient)
                                : AnyShapeStyle(.ultraThinMaterial),
                            in: Capsule()
                        )
                        .background(Color.black.opacity(0.32), in: Capsule())
                        .foregroundStyle(selection == mode ? Color.black : Color.white)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - パーツインスペクタ

/// タップしたパーツ(壁・家具・ピンなど)の情報カード
struct PartInspectorCard: View {
    let info: RoomPartInfo
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: info.symbolName)
                    .foregroundStyle(Theme.accentCyan)
                Text(info.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            if let subtitle = info.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            switch info.kind {
            case .memoPin(let pin):
                if !pin.body.isEmpty {
                    Text(pin.body)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(4)
                }
                Text(pin.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
            default:
                Text(info.sizeText)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(14)
        .glassCard()
    }
}

// MARK: - AR 非対応フォールバック

struct ARUnavailableCard: View {
    var title: String
    var message: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arkit")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accentCyan)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(26)
        .glassCard(cornerRadius: 26)
        .padding(24)
    }
}
