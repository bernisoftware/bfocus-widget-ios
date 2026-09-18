#if canImport(UIKit) && os(iOS)
import SwiftUI
import BFocusWidgetCore

/// Ícone do widget web como `Shape` do SwiftUI.
struct BFocusIconShape: Shape {
    enum Kind {
        case balloon
        case balloonDots
        case star
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let base: CGPath
        switch kind {
        case .balloon: base = BFocusIcons.balloon
        case .balloonDots: base = BFocusIcons.balloonDots
        case .star: base = BFocusIcons.star
        }
        return Path(BFocusIcons.fit(base, in: rect))
    }
}

/// Botão flutuante (56 pt) com badge, ligado ao `BFocus.shared`.
///
/// ```swift
/// ZStack(alignment: .bottomTrailing) {
///     ConteudoDoApp()
///     BFocusLauncher().padding(20)
/// }
/// ```
@MainActor
public struct BFocusLauncher: View {
    @ObservedObject private var bfocus: BFocus
    private let target: BFocusTarget?

    public init(target: BFocusTarget? = nil) {
        self.target = target
        self._bfocus = ObservedObject(wrappedValue: BFocus.shared)
    }

    public var body: some View {
        Button {
            bfocus.open(target)
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(Color(BFocusColor.brand(bfocus.primaryColor)))
                        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
                    BFocusIconShape(kind: .balloon)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8 * 26 / 24, lineCap: .round, lineJoin: .round))
                        .frame(width: 26, height: 26)
                    BFocusIconShape(kind: .balloonDots)
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 56, height: 56)

                if !bfocus.badgeLabel.isEmpty {
                    Text(bfocus.badgeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18)
                        .frame(height: 18)
                        .background(Capsule().fill(Color(BFocusColor.badge)))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BFocusStrings.forLocale(bfocus.config?.locale ?? .device).launcher))
        .accessibilityValue(Text(bfocus.badgeLabel))
    }
}

/// Pílula de versão (`v4.2.0` ou `—`, com ponto quando há novidade). Tocar abre o histórico.
@MainActor
public struct BFocusReleaseBadge: View {
    @ObservedObject private var bfocus: BFocus

    public init() {
        self._bfocus = ObservedObject(wrappedValue: BFocus.shared)
    }

    private var color: Color {
        // Marca do tenant primeiro; a cor do produto é só fallback (igual ao web).
        let hex = (bfocus.primaryColor?.isEmpty == false) ? bfocus.primaryColor : bfocus.releaseNotes.productColor
        return Color(BFocusColor.brand(hex))
    }

    public var body: some View {
        Button {
            bfocus.openReleaseNotesHistory()
        } label: {
            HStack(spacing: 6) {
                BFocusIconShape(kind: .star)
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                Text(bfocus.releaseNotes.label)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if bfocus.releaseNotes.dot {
                    Circle()
                        .fill(Color(BFocusColor.badge))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(color, lineWidth: 2))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BFocusStrings.forLocale(bfocus.config?.locale ?? .device).releaseBadge))
        .accessibilityValue(Text(bfocus.releaseNotes.label))
    }
}
#endif
