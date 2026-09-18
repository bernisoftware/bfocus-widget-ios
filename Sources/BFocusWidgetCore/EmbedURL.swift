import Foundation

/// Tela inicial do widget de chamados (`open(target)`).
public enum BFocusTarget: Equatable, Sendable {
    /// Lista de chamados (padrão do embed).
    case list
    /// Formulário de novo chamado.
    case new
    /// Chat ao vivo (a conversa ativa, se houver).
    case chat
    /// Um chamado específico.
    case ticket(String)
    /// Uma conversa de chat específica (vem do push `chat.message`).
    case conversation(String)

    /// Valor do `open=` na URL, usado só no primeiro carregamento. `list` é o padrão do embed
    /// e não entra na URL (a URL mínima fica idêntica à do contrato).
    public var openParameter: String? {
        switch self {
        case .list: return nil
        case .new: return "new"
        case .chat, .conversation: return "chat"
        case .ticket(let id): return "ticket:" + id
        }
    }

    /// Payload do `bfocus:navigate`, usado quando a WebView já está carregada.
    public var navigation: BFocusNavigation {
        switch self {
        case .list: return BFocusNavigation(view: "list")
        case .new: return BFocusNavigation(view: "new")
        case .chat: return BFocusNavigation(view: "chat")
        case .ticket(let id): return BFocusNavigation(view: "ticket", ticketId: id)
        case .conversation(let id): return BFocusNavigation(view: "chat", conversationId: id)
        }
    }

    public init(navigation: BFocusNavigation) {
        switch navigation.view {
        case "ticket":
            if let id = navigation.ticketId { self = .ticket(id) } else { self = .list }
        case "chat":
            if let id = navigation.conversationId { self = .conversation(id) } else { self = .chat }
        case "new":
            self = .new
        default:
            self = .list
        }
    }
}

/// Payload de `bfocus:navigate`: `{view, ticketId?, conversationId?}`.
public struct BFocusNavigation: Equatable, Sendable {
    public var view: String
    public var ticketId: String?
    public var conversationId: String?

    public init(view: String, ticketId: String? = nil, conversationId: String? = nil) {
        self.view = view
        self.ticketId = ticketId
        self.conversationId = conversationId
    }

    /// Para comparar com `scenarios.json` como objeto.
    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["view": view]
        if let ticketId { out["ticketId"] = ticketId }
        if let conversationId { out["conversationId"] = conversationId }
        return out
    }

    public var json: String {
        var members: [(String, String)] = [("view", BFocusJSONText.string(view))]
        if let ticketId { members.append(("ticketId", BFocusJSONText.string(ticketId))) }
        if let conversationId { members.append(("conversationId", BFocusJSONText.string(conversationId))) }
        return BFocusJSONText.object(members)
    }
}

/// Página do embed na CDN.
public enum BFocusPage: Equatable, Sendable {
    case tickets
    case releaseNotesBanner(ids: [String])
    case releaseNotesHistory

    public var fileName: String {
        switch self {
        case .tickets: return "embed.html"
        case .releaseNotesBanner, .releaseNotesHistory: return "release-notes.html"
        }
    }
}

/// `native` = dentro da WebView do pacote; `browser` = página inteira no navegador.
public enum BFocusHostMode: String, Sendable {
    case native
    case browser
}

/// URL do embed (Host Protocol §1). Os parâmetros vão no FRAGMENTO para a identidade não
/// chegar aos logs da CDN.
public enum BFocusEmbedURL {
    public static func string(
        for config: BFocusResolvedConfig,
        page: BFocusPage = .tickets,
        mode: BFocusHostMode = .native,
        open target: BFocusTarget? = nil
    ) -> String {
        // Ordem fixa, igual ao generate.mjs: a string tem de bater byte a byte.
        var params: [(String, String)] = [
            ("host", mode.rawValue),
            ("hp", String(BFocusWidgetInfo.hostProtocol)),
            ("client", config.client),
            ("key", config.publishableKey),
            ("user", config.userBase64),
            ("locale", config.locale.rawValue),
            ("parentOrigin", config.parentOrigin),
        ]
        if let product = config.product, !product.isEmpty { params.append(("product", product)) }
        if let audience = config.audience { params.append(("audience", audience.rawValue)) }
        if config.apiBase != BFocusResolvedConfig.defaultApiBase { params.append(("api", config.apiBase)) }
        if page == .tickets, !config.showReleaseNotes { params.append(("showReleaseNotes", "0")) }
        if page == .tickets, let open = target?.openParameter { params.append(("open", open)) }
        switch page {
        case .tickets:
            break
        case .releaseNotesBanner(let ids):
            params.append(("view", "banner"))
            if !ids.isEmpty { params.append(("ids", ids.joined(separator: ","))) }
        case .releaseNotesHistory:
            params.append(("view", "history"))
        }
        let fragment = params
            .map { "\($0.0)=\(BFocusURLEncoding.component($0.1))" }
            .joined(separator: "&")
        return "\(config.embedBase)/\(page.fileName)#\(fragment)"
    }

    public static func url(
        for config: BFocusResolvedConfig,
        page: BFocusPage = .tickets,
        mode: BFocusHostMode = .native,
        open target: BFocusTarget? = nil
    ) -> URL? {
        URL(string: string(for: config, page: page, mode: mode, open: target))
    }
}

/// Origem (esquema + host + porta) no sentido do navegador. A ponte e a navegação da WebView
/// só aceitam a origem de `embedBaseUrl`.
public struct BFocusOrigin: Equatable, Sendable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        self.init(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// `port` 0 = porta padrão do esquema (é o que o `WKSecurityOrigin` devolve).
    public init(scheme: String, host: String, port: Int) {
        let s = scheme.lowercased()
        self.scheme = s
        self.host = host.lowercased()
        self.port = port == 0 ? Self.defaultPort(for: s) : port
    }

    public static func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return 0
        }
    }

    public func matches(_ url: URL) -> Bool { BFocusOrigin(url: url) == self }

    public var description: String {
        port == Self.defaultPort(for: scheme) ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}
