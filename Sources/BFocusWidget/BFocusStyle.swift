import CoreGraphics
import BFocusWidgetCore

/// Textos da casca nativa (o resto mora no embed). Quando o texto existe em
/// widget/src/shared/i18n/*.json, é o mesmo de lá (loading, btn_retry, csat_error_network).
struct BFocusStrings {
    let loading: String
    let offlineTitle: String
    let offlineMessage: String
    let retry: String
    let close: String
    let launcher: String
    let releaseBadge: String
    let downloadFailed: String
    let ok: String
    let cancel: String

    static func forLocale(_ locale: BFocusLocale) -> BFocusStrings {
        switch locale {
        case .ptBR:
            return BFocusStrings(
                loading: "Carregando...",
                offlineTitle: "Sem conexão",
                offlineMessage: "Sem conexão com o servidor. Verifique sua internet e tente de novo.",
                retry: "Tentar novamente",
                close: "Fechar",
                launcher: "Abrir chamados",
                releaseBadge: "Novidades e versão",
                downloadFailed: "Não foi possível baixar o arquivo.",
                ok: "OK",
                cancel: "Cancelar"
            )
        case .en:
            return BFocusStrings(
                loading: "Loading...",
                offlineTitle: "No connection",
                offlineMessage: "Could not reach the server. Check your internet connection and try again.",
                retry: "Try again",
                close: "Close",
                launcher: "Open support tickets",
                releaseBadge: "What's new and version",
                downloadFailed: "Could not download the file.",
                ok: "OK",
                cancel: "Cancel"
            )
        case .es:
            return BFocusStrings(
                loading: "Cargando...",
                offlineTitle: "Sin conexión",
                offlineMessage: "Sin conexión con el servidor. Revisa tu internet e inténtalo de nuevo.",
                retry: "Reintentar",
                close: "Cerrar",
                launcher: "Abrir tickets de soporte",
                releaseBadge: "Novedades y versión",
                downloadFailed: "No se pudo descargar el archivo.",
                ok: "Aceptar",
                cancel: "Cancelar"
            )
        }
    }
}

/// Ícones do widget web (mesmos SVGs, viewBox 24×24), como CGPath.
enum BFocusIcons {
    /// Balão do botão (launcher/bootstrap.ts → ICON_SVG), traço.
    static let balloon: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3, y: 11))
        p.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 3, y: 6.6), control2: CGPoint(x: 7, y: 3))
        p.addCurve(to: CGPoint(x: 21, y: 11), control1: CGPoint(x: 17, y: 3), control2: CGPoint(x: 21, y: 6.6))
        p.addCurve(to: CGPoint(x: 12, y: 19), control1: CGPoint(x: 21, y: 15.4), control2: CGPoint(x: 17, y: 19))
        p.addCurve(to: CGPoint(x: 9.1, y: 18.6), control1: CGPoint(x: 11, y: 19), control2: CGPoint(x: 10, y: 18.9))
        p.addLine(to: CGPoint(x: 4, y: 21))
        p.addLine(to: CGPoint(x: 5.4, y: 16.6))
        p.addCurve(to: CGPoint(x: 3, y: 11), control1: CGPoint(x: 4, y: 15.2), control2: CGPoint(x: 3, y: 13.2))
        p.closeSubpath()
        return p
    }()

    /// Os três pontos do balão, preenchidos.
    static let balloonDots: CGPath = {
        let p = CGMutablePath()
        for x in [9.0, 12.0, 15.0] {
            p.addEllipse(in: CGRect(x: x - 1, y: 10, width: 2, height: 2))
        }
        return p
    }()

    /// Estrela da pílula de versão (launcher-release-notes/bootstrap.ts → STAR_SVG).
    static let star: CGPath = {
        let points: [CGPoint] = [
            CGPoint(x: 12, y: 2), CGPoint(x: 14.4, y: 9.4), CGPoint(x: 22, y: 9.4), CGPoint(x: 16, y: 13.8),
            CGPoint(x: 18.3, y: 21.2), CGPoint(x: 12, y: 16.6), CGPoint(x: 5.7, y: 21.2), CGPoint(x: 7.9, y: 13.8),
            CGPoint(x: 2, y: 9.4), CGPoint(x: 9.6, y: 9.4),
        ]
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }()

    /// Escala o ícone de 24×24 para caber centralizado em `rect`.
    static func fit(_ path: CGPath, in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 24
        var transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - 24 * scale) / 2,
            y: rect.minY + (rect.height - 24 * scale) / 2
        ).scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}

#if canImport(UIKit)
import UIKit

enum BFocusColor {
    /// tokens.json → brandFallback (identidade bFocus).
    static let brandFallbackHex = "#6366F1"
    /// Vermelho do badge/ponto no web.
    static let badgeHex = "#EF4444"

    static func uiColor(hex: String?) -> UIColor? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Cor do tenant; vazio ou inválido cai na identidade bFocus (o backend manda `''`).
    static func brand(_ hex: String?) -> UIColor {
        uiColor(hex: hex) ?? uiColor(hex: brandFallbackHex)!
    }

    static var badge: UIColor { uiColor(hex: badgeHex)! }
    static var text: UIColor { uiColor(hex: "#0F172A")! }
    static var muted: UIColor { uiColor(hex: "#64748B")! }
    static var subtle: UIColor { uiColor(hex: "#94A3B8")! }
}
#endif
