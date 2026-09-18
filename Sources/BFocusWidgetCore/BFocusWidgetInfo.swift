import Foundation

/// Identificação do pacote.
///
/// `version` é a versão publicada: o `publish.yml` do espelho confere que a tag `vX.Y.Z`
/// bate com esta constante antes de criar a release (o SwiftPM consome a tag).
public enum BFocusWidgetInfo {
    public static let version = "0.1.0"

    /// Família do header `X-bFocus-Client` (BRIEF §2).
    public static let clientFamily = "ios"

    /// Versão do Host Protocol falada com o embed (`hp=1`).
    public static let hostProtocol = 1

    /// Valor do header `X-bFocus-Client` e do parâmetro `client` do embed.
    public static var client: String { "\(clientFamily)/\(version)" }
}
