import Foundation

/// `data` de `POST /api/v1/widget/launcher-state` (Host Protocol §4). Campos ausentes viram
/// padrão: o contrato só cresce de forma aditiva e o pacote não pode quebrar por isso.
public struct BFocusLauncherState: Equatable, Sendable, Decodable {
    public struct Tickets: Equatable, Sendable, Decodable {
        public var openCount: Int
        public var totalCount: Int
        public var latestEventAt: String?

        public init(openCount: Int = 0, totalCount: Int = 0, latestEventAt: String? = nil) {
            self.openCount = openCount
            self.totalCount = totalCount
            self.latestEventAt = latestEventAt
        }

        enum CodingKeys: String, CodingKey {
            case openCount = "open_count"
            case totalCount = "total_count"
            case latestEventAt = "latest_event_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            openCount = (try? c.decodeIfPresent(Int.self, forKey: .openCount)) ?? 0
            totalCount = (try? c.decodeIfPresent(Int.self, forKey: .totalCount)) ?? 0
            latestEventAt = try? c.decodeIfPresent(String.self, forKey: .latestEventAt)
        }
    }

    public struct Chat: Equatable, Sendable, Decodable {
        public var enabled: Bool
        public var activeConversationId: String?
        public var unread: Int?

        public init(enabled: Bool = false, activeConversationId: String? = nil, unread: Int? = nil) {
            self.enabled = enabled
            self.activeConversationId = activeConversationId
            self.unread = unread
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case activeConversationId = "active_conversation_id"
            case unread
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            activeConversationId = try? c.decodeIfPresent(String.self, forKey: .activeConversationId)
            unread = try? c.decodeIfPresent(Int.self, forKey: .unread)
        }
    }

    public var primaryColor: String?
    public var tickets: Tickets
    public var chat: Chat
    public var releaseNotes: BFocusReleaseNotesPayload

    public init(
        primaryColor: String? = nil,
        tickets: Tickets = Tickets(),
        chat: Chat = Chat(),
        releaseNotes: BFocusReleaseNotesPayload = BFocusReleaseNotesPayload()
    ) {
        self.primaryColor = primaryColor
        self.tickets = tickets
        self.chat = chat
        self.releaseNotes = releaseNotes
    }

    enum CodingKeys: String, CodingKey {
        case primaryColor = "primary_color"
        case tickets
        case chat
        case releaseNotes = "release_notes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryColor = try? c.decodeIfPresent(String.self, forKey: .primaryColor)
        tickets = (try? c.decodeIfPresent(Tickets.self, forKey: .tickets)) ?? Tickets()
        chat = (try? c.decodeIfPresent(Chat.self, forKey: .chat)) ?? Chat()
        releaseNotes = (try? c.decodeIfPresent(BFocusReleaseNotesPayload.self, forKey: .releaseNotes))
            ?? BFocusReleaseNotesPayload()
    }

    private struct Envelope: Decodable {
        let data: BFocusLauncherState?
    }

    /// Lê o envelope `{code, data, message}`.
    public static func decodeEnvelope(_ body: Data) throws -> BFocusLauncherState {
        let envelope = try JSONDecoder().decode(Envelope.self, from: body)
        guard let data = envelope.data else {
            throw DecodingError.valueNotFound(
                BFocusLauncherState.self,
                .init(codingPath: [], debugDescription: "envelope sem data")
            )
        }
        return data
    }
}

/// `release_notes` do launcher-state. A regra da fila do banner já vem aplicada pelo servidor.
public struct BFocusReleaseNotesPayload: Equatable, Sendable, Decodable {
    public struct Product: Equatable, Sendable, Decodable {
        public var slug: String?
        public var name: String?
        public var color: String?

        public init(slug: String? = nil, name: String? = nil, color: String? = nil) {
            self.slug = slug
            self.name = name
            self.color = color
        }
    }

    public var badgeVersion: String?
    public var product: Product?
    public var bannerIds: [String]
    public var hasUnseen: Bool

    public init(badgeVersion: String? = nil, product: Product? = nil, bannerIds: [String] = [], hasUnseen: Bool = false) {
        self.badgeVersion = badgeVersion
        self.product = product
        self.bannerIds = bannerIds
        self.hasUnseen = hasUnseen
    }

    enum CodingKeys: String, CodingKey {
        case badgeVersion = "badge_version"
        case product
        case bannerIds = "banner_ids"
        case hasUnseen = "has_unseen"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        badgeVersion = try? c.decodeIfPresent(String.self, forKey: .badgeVersion)
        product = try? c.decodeIfPresent(Product.self, forKey: .product)
        bannerIds = (try? c.decodeIfPresent([String].self, forKey: .bannerIds)) ?? []
        hasUnseen = (try? c.decodeIfPresent(Bool.self, forKey: .hasUnseen)) ?? false
    }
}

/// Pílula de versão (`scenarios.pill`).
public struct BFocusReleaseNotesState: Equatable, Sendable {
    /// `v4.2.0`, `—` sem produto, ou `…` antes da primeira resposta (igual ao web).
    public var label: String
    /// Ponto aceso quando há novidade não vista.
    public var dot: Bool
    /// Fila do banner, na ordem.
    public var bannerIds: [String]
    /// Cor do produto: só fallback, a marca do tenant (`primary_color`) tem prioridade.
    public var productColor: String?

    public static let placeholder = BFocusReleaseNotesState(label: "…", dot: false, bannerIds: [], productColor: nil)

    public init(label: String, dot: Bool, bannerIds: [String], productColor: String? = nil) {
        self.label = label
        self.dot = dot
        self.bannerIds = bannerIds
        self.productColor = productColor
    }

    public init(payload: BFocusReleaseNotesPayload) {
        self.init(
            label: Self.label(forVersion: payload.badgeVersion),
            dot: payload.hasUnseen,
            bannerIds: payload.bannerIds,
            productColor: payload.product?.color
        )
    }

    /// `4.2.0` → `v4.2.0`; `V3.0.0` → `v3.0.0`; nulo/vazio → `—`.
    public static func label(forVersion version: String?) -> String {
        let trimmed = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = (trimmed.first == "v" || trimmed.first == "V") ? String(trimmed.dropFirst()) : trimmed
        return bare.isEmpty ? "—" : "v" + bare
    }
}
