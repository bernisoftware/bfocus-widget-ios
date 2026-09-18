import Foundation

/// Usuário final do app do integrador (quem abre os chamados).
public struct BFocusUser: Equatable, Sendable {
    public var externalId: String
    public var name: String?
    public var email: String?
    public var phone: String?

    public init(externalId: String, name: String? = nil, email: String? = nil, phone: String? = nil) {
        self.externalId = externalId
        self.name = name
        self.email = email
        self.phone = phone
    }
}

/// Empresa (cliente do integrador) à qual o usuário pertence.
public struct BFocusCustomer: Equatable, Sendable {
    public var externalId: String
    public var name: String?
    public var document: String?
    public var email: String?
    public var phone: String?
    public var website: String?

    public init(
        externalId: String,
        name: String? = nil,
        document: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        website: String? = nil
    ) {
        self.externalId = externalId
        self.name = name
        self.document = document
        self.email = email
        self.phone = phone
        self.website = website
    }
}

public enum BFocusAudience: String, Sendable, CaseIterable {
    case external
    case `internal`
    case both
}

public enum BFocusLocale: String, Sendable, CaseIterable {
    case ptBR = "pt_BR"
    case en
    case es

    /// Mapeamento do contrato: `pt*` → pt_BR, `es*` → es, o resto → en.
    public init(languageTag: String) {
        let tag = languageTag.lowercased()
        if tag.hasPrefix("pt") {
            self = .ptBR
        } else if tag.hasPrefix("es") {
            self = .es
        } else {
            self = .en
        }
    }

    /// Idioma preferido do aparelho, já mapeado.
    public static var device: BFocusLocale {
        BFocusLocale(languageTag: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }
}

public enum BFocusConfigError: Error, Equatable, LocalizedError {
    /// Chave secreta (`bf_whs_`, `bf_live_`, `bf_sk_`) no app: nunca pode.
    case secretKeyInApp
    case invalidPublishableKey
    case missingAppId
    case missingUserExternalId
    case missingCustomerExternalId
    /// `http://` fora de 127.0.0.1/localhost.
    case insecureURL(String)

    public var errorDescription: String? {
        switch self {
        case .secretKeyInApp:
            return "bFocus: esta chave é SECRETA (bf_whs_/bf_live_/bf_sk_) e nunca pode ir no app. "
                + "Use a chave pública bf_pk_… e calcule o userHash no seu servidor."
        case .invalidPublishableKey:
            return "bFocus: publishableKey tem de ser a chave pública bf_pk_…"
        case .missingAppId:
            return "bFocus: appId vazio e o bundle id do app não foi encontrado."
        case .missingUserExternalId:
            return "bFocus: user.externalId é obrigatório."
        case .missingCustomerExternalId:
            return "bFocus: customer.externalId é obrigatório."
        case .insecureURL(let url):
            return "bFocus: \(url) precisa ser https (http só para 127.0.0.1/localhost, em testes)."
        }
    }
}

/// Configuração do `initialize` (BRIEF §3).
public struct BFocusConfig: Sendable {
    public static let defaultApiBaseUrl = URL(string: "https://api.bfocus.com.br")!
    public static let defaultEmbedBaseUrl = URL(string: "https://widget.bfocus.com.br/v1")!
    public static let defaultPollIntervalSeconds: TimeInterval = 60

    /// Chave pública `bf_pk_…`.
    public var publishableKey: String
    /// Bundle id cadastrado em Integrações → Apps nativos. `nil` = `Bundle.main.bundleIdentifier`.
    public var appId: String?
    public var user: BFocusUser
    public var customer: BFocusCustomer
    /// HMAC calculado no SERVIDOR do integrador (`sign_widget_identity` dos SDKs do bFocus).
    public var userHash: String?
    /// Busca um `userHash` novo; chamado de novo após `WIDGET_USER_HASH_INVALID`.
    public var userHashProvider: (@Sendable () async throws -> String)?
    public var product: String?
    public var audience: BFocusAudience?
    /// `nil` = idioma do aparelho.
    public var locale: BFocusLocale?
    public var showReleaseNotes: Bool
    public var autoShowReleaseBanner: Bool
    public var apiBaseUrl: URL
    public var embedBaseUrl: URL
    public var pollIntervalSeconds: TimeInterval

    public init(
        publishableKey: String,
        appId: String? = nil,
        user: BFocusUser,
        customer: BFocusCustomer,
        userHash: String? = nil,
        userHashProvider: (@Sendable () async throws -> String)? = nil,
        product: String? = nil,
        audience: BFocusAudience? = nil,
        locale: BFocusLocale? = nil,
        showReleaseNotes: Bool = true,
        autoShowReleaseBanner: Bool = true,
        apiBaseUrl: URL = BFocusConfig.defaultApiBaseUrl,
        embedBaseUrl: URL = BFocusConfig.defaultEmbedBaseUrl,
        pollIntervalSeconds: TimeInterval = BFocusConfig.defaultPollIntervalSeconds
    ) {
        self.publishableKey = publishableKey
        self.appId = appId
        self.user = user
        self.customer = customer
        self.userHash = userHash
        self.userHashProvider = userHashProvider
        self.product = product
        self.audience = audience
        self.locale = locale
        self.showReleaseNotes = showReleaseNotes
        self.autoShowReleaseBanner = autoShowReleaseBanner
        self.apiBaseUrl = apiBaseUrl
        self.embedBaseUrl = embedBaseUrl
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    /// Valida e resolve os padrões da plataforma. Erro de programação (chave secreta, http em
    /// produção) falha aqui, antes de qualquer chamada.
    public func resolved(
        defaultAppId: String? = Bundle.main.bundleIdentifier,
        client: String = BFocusWidgetInfo.client,
        deviceLocale: BFocusLocale = .device
    ) throws -> BFocusResolvedConfig {
        let key = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        for secret in ["bf_whs_", "bf_live_", "bf_sk_"] where key.hasPrefix(secret) {
            throw BFocusConfigError.secretKeyInApp
        }
        guard key.hasPrefix("bf_pk_"), key.count > "bf_pk_".count else {
            throw BFocusConfigError.invalidPublishableKey
        }
        let app = (appId ?? defaultAppId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty else { throw BFocusConfigError.missingAppId }
        guard !user.externalId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BFocusConfigError.missingUserExternalId
        }
        guard !customer.externalId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BFocusConfigError.missingCustomerExternalId
        }
        try Self.checkSecure(apiBaseUrl)
        try Self.checkSecure(embedBaseUrl)

        let hash = userHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BFocusResolvedConfig(
            publishableKey: key,
            appId: app,
            client: client,
            user: user,
            customer: customer,
            userHash: (hash?.isEmpty ?? true) ? nil : hash,
            locale: locale ?? deviceLocale,
            product: product,
            audience: audience,
            showReleaseNotes: showReleaseNotes,
            apiBase: apiBaseUrl.absoluteString,
            embedBase: embedBaseUrl.absoluteString,
            pollIntervalSeconds: pollIntervalSeconds > 0 ? pollIntervalSeconds : Self.defaultPollIntervalSeconds,
            autoShowReleaseBanner: autoShowReleaseBanner
        )
    }

    /// BRIEF §6: `http://` só para 127.0.0.1/localhost (testes com o servidor simulado).
    static func checkSecure(_ url: URL) throws {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        if scheme == "https", !host.isEmpty { return }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return }
        throw BFocusConfigError.insecureURL(url.absoluteString)
    }
}

/// Configuração já validada: é dela que saem a URL do embed, os headers e o payload.
public struct BFocusResolvedConfig: Equatable, Sendable {
    public static let defaultApiBase = "https://api.bfocus.com.br"
    public static let defaultEmbedBase = "https://widget.bfocus.com.br/v1"

    public var publishableKey: String
    /// Como o integrador passou; a origem usa minúsculas.
    public var appId: String
    /// `<família>/<versão>`, ex.: `ios/0.1.0`.
    public var client: String
    public var user: BFocusUser
    public var customer: BFocusCustomer
    public var userHash: String?
    public var locale: BFocusLocale
    public var product: String?
    public var audience: BFocusAudience?
    public var showReleaseNotes: Bool
    /// Sem barra no fim.
    public var apiBase: String
    /// Sem barra no fim.
    public var embedBase: String
    public var pollIntervalSeconds: TimeInterval
    public var autoShowReleaseBanner: Bool

    public init(
        publishableKey: String,
        appId: String,
        client: String = BFocusWidgetInfo.client,
        user: BFocusUser,
        customer: BFocusCustomer,
        userHash: String? = nil,
        locale: BFocusLocale = .ptBR,
        product: String? = nil,
        audience: BFocusAudience? = nil,
        showReleaseNotes: Bool = true,
        apiBase: String = BFocusResolvedConfig.defaultApiBase,
        embedBase: String = BFocusResolvedConfig.defaultEmbedBase,
        pollIntervalSeconds: TimeInterval = BFocusConfig.defaultPollIntervalSeconds,
        autoShowReleaseBanner: Bool = true
    ) {
        self.publishableKey = publishableKey
        self.appId = appId
        self.client = client
        self.user = user
        self.customer = customer
        self.userHash = userHash
        self.locale = locale
        self.product = product
        self.audience = audience
        self.showReleaseNotes = showReleaseNotes
        self.apiBase = Self.trimSlash(apiBase)
        self.embedBase = Self.trimSlash(embedBase)
        self.pollIntervalSeconds = pollIntervalSeconds
        self.autoShowReleaseBanner = autoShowReleaseBanner
    }

    static func trimSlash(_ value: String) -> String {
        var out = value
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// `app://<bundle id em minúsculas>`: o rótulo cadastrado em Apps nativos.
    public var parentOrigin: String { "app://" + appId.lowercased() }

    public var userJSON: String {
        BFocusUserPayload.json(user: user, customer: customer, userHash: userHash, locale: locale)
    }

    public var userBase64: String { BFocusUserPayload.base64(ofJSON: userJSON) }

    public var lastSeenStorageKey: String {
        BFocusBadgeModel.storageKey(
            publishableKey: publishableKey,
            userExternalId: user.externalId,
            customerExternalId: customer.externalId
        )
    }

    /// Única origem aceita na ponte e na navegação da WebView.
    public var embedOrigin: BFocusOrigin? { URL(string: embedBase).flatMap(BFocusOrigin.init(url:)) }
}
