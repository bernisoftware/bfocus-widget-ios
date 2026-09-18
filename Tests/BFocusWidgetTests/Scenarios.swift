import Foundation
import BFocusWidgetCore

/// Lê a cópia de scenarios.json (gerada por generate.mjs; nunca editar).
enum Scenarios {
    static let root: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "scenarios", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("scenarios.json ausente: rode node widgets-native/conformance/generate.mjs")
        }
        return object
    }()

    static func list(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }

    static var push: [String: Any] { root["push"] as? [String: Any] ?? [:] }

    static var defaults: [String: Any] { root["defaults"] as? [String: Any] ?? [:] }

    static func rawConfig(_ name: String) -> [String: Any] {
        (root["configs"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    static func fixture(_ name: String) -> [String: Any] {
        (root["launcherStateFixtures"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    static func mockScript(_ name: String) -> [[String: Any]] {
        (root["mockEmbedScript"] as? [String: Any])?[name] as? [[String: Any]] ?? []
    }

    static func user(_ raw: [String: Any]) -> BFocusUser {
        BFocusUser(
            externalId: raw["externalId"] as? String ?? "",
            name: raw["name"] as? String,
            email: raw["email"] as? String,
            phone: raw["phone"] as? String
        )
    }

    static func customer(_ raw: [String: Any]) -> BFocusCustomer {
        BFocusCustomer(
            externalId: raw["externalId"] as? String ?? "",
            name: raw["name"] as? String,
            document: raw["document"] as? String,
            email: raw["email"] as? String,
            phone: raw["phone"] as? String,
            website: raw["website"] as? String
        )
    }

    /// Config do cenário montada direto (com o `client` do cenário).
    static func config(_ name: String) -> BFocusResolvedConfig {
        let c = rawConfig(name)
        let locale = (c["locale"] as? String) ?? (defaults["locale"] as? String) ?? "pt_BR"
        return BFocusResolvedConfig(
            publishableKey: c["publishableKey"] as? String ?? "",
            appId: c["appId"] as? String ?? "",
            client: c["client"] as? String ?? BFocusWidgetInfo.client,
            user: user(c["user"] as? [String: Any] ?? [:]),
            customer: customer(c["customer"] as? [String: Any] ?? [:]),
            userHash: c["userHash"] as? String,
            locale: BFocusLocale(rawValue: locale) ?? .ptBR,
            product: c["product"] as? String,
            audience: (c["audience"] as? String).flatMap(BFocusAudience.init(rawValue:)),
            showReleaseNotes: c["showReleaseNotes"] as? Bool ?? true,
            apiBase: c["apiBaseUrl"] as? String ?? defaults["apiBaseUrl"] as? String ?? "",
            embedBase: c["embedBaseUrl"] as? String ?? defaults["embedBaseUrl"] as? String ?? ""
        )
    }

    /// A mesma config pelo caminho público (`BFocusConfig.resolved`).
    static func publicConfig(_ name: String) throws -> BFocusResolvedConfig {
        let c = rawConfig(name)
        let config = BFocusConfig(
            publishableKey: c["publishableKey"] as? String ?? "",
            appId: c["appId"] as? String,
            user: user(c["user"] as? [String: Any] ?? [:]),
            customer: customer(c["customer"] as? [String: Any] ?? [:]),
            userHash: c["userHash"] as? String,
            product: c["product"] as? String,
            audience: (c["audience"] as? String).flatMap(BFocusAudience.init(rawValue:)),
            locale: (c["locale"] as? String).flatMap(BFocusLocale.init(rawValue:)),
            showReleaseNotes: c["showReleaseNotes"] as? Bool ?? true,
            apiBaseUrl: (c["apiBaseUrl"] as? String).flatMap(URL.init(string:)) ?? BFocusConfig.defaultApiBaseUrl
        )
        // Sem locale no cenário = padrão do contrato (pt_BR), não o do Mac que roda o teste.
        return try config.resolved(defaultAppId: nil, client: c["client"] as? String ?? BFocusWidgetInfo.client, deviceLocale: .ptBR)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
