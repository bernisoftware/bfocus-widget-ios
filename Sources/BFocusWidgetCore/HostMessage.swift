import Foundation

/// Mensagem embed → pacote (Host Protocol §3). Só os tipos conhecidos; o resto é ignorado.
public enum BFocusHostMessage: Equatable, Sendable {
    case ready(hp: Int?, widget: String?, view: String?)
    case close
    case unread(count: Int)
    case seen(latestEventAt: String?)
    case branding(primaryColor: String?)
    case error(BFocusError)
    case openExternal(URL)
    case download(url: URL, filename: String)
    case releaseNotesBranding(primaryColor: String?)
    case releaseNotesDone
    case releaseNotesCloseHistory

    /// Esquemas que o `openExternal` pode abrir fora (nada de `javascript:`, `file:`…).
    public static let externalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    public var type: String {
        switch self {
        case .ready: return "bfocus:ready"
        case .close: return "bfocus:close"
        case .unread: return "bfocus:unread"
        case .seen: return "bfocus:seen"
        case .branding: return "bfocus:branding"
        case .error: return "bfocus:error"
        case .openExternal: return "bfocus:openExternal"
        case .download: return "bfocus:download"
        case .releaseNotesBranding: return "bfocus:rn:branding"
        case .releaseNotesDone: return "bfocus:rn:done"
        case .releaseNotesCloseHistory: return "bfocus:rn:closeHistory"
        }
    }

    /// Lê a string JSON que o embed manda (ou um objeto já decodificado). Tipo desconhecido ou
    /// payload inválido → `nil`.
    public static func parse(_ body: Any) -> BFocusHostMessage? {
        let object: [String: Any]
        if let text = body as? String {
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            object = decoded
        } else if let dictionary = body as? [String: Any] {
            object = dictionary
        } else {
            return nil
        }
        guard let type = object["type"] as? String else { return nil }
        let payload = object["payload"] as? [String: Any] ?? [:]

        switch type {
        case "bfocus:ready":
            return .ready(hp: int(payload["hp"]), widget: text(payload["widget"]), view: text(payload["view"]))
        case "bfocus:close":
            return .close
        case "bfocus:unread":
            return .unread(count: max(0, int(payload["count"]) ?? 0))
        case "bfocus:seen":
            return .seen(latestEventAt: text(payload["latest_event_at"]))
        case "bfocus:branding":
            return .branding(primaryColor: text(payload["primary_color"]))
        case "bfocus:error":
            guard let code = text(payload["code"]) else { return nil }
            return .error(BFocusError(code: code, detail: text(payload["detail"])))
        case "bfocus:openExternal":
            guard let raw = text(payload["url"]), let url = URL(string: raw),
                  externalSchemes.contains(url.scheme?.lowercased() ?? "") else { return nil }
            return .openExternal(url)
        case "bfocus:download":
            guard let raw = text(payload["url"]), let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let name = BFocusFileName.sanitize(text(payload["filename"]), fallback: url.lastPathComponent)
            return .download(url: url, filename: name)
        case "bfocus:rn:branding":
            return .releaseNotesBranding(primaryColor: text(payload["primary_color"]))
        case "bfocus:rn:done":
            return .releaseNotesDone
        case "bfocus:rn:closeHistory":
            return .releaseNotesCloseHistory
        default:
            return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// Mensagem pacote → embed.
public enum BFocusHostCommand: Equatable, Sendable {
    /// Widget visível: liga o stream do chat.
    case open
    /// Widget oculto sem destruir a WebView: desliga o stream (obrigatório).
    case close
    /// Troca de tela (push, `open(target)` com a WebView já carregada).
    case navigate(BFocusNavigation)

    public var json: String {
        switch self {
        case .open:
            return BFocusJSONText.object([("type", BFocusJSONText.string("bfocus:open"))])
        case .close:
            return BFocusJSONText.object([("type", BFocusJSONText.string("bfocus:close"))])
        case .navigate(let navigation):
            return BFocusJSONText.object([
                ("type", BFocusJSONText.string("bfocus:navigate")),
                ("payload", navigation.json),
            ])
        }
    }

    /// Script do contrato (BRIEF §4.3); não quebra se a ponte do embed ainda não existir.
    public var script: String {
        "window.bFocusEmbed && window.bFocusEmbed.receive(\(json))"
    }
}

/// Nome de arquivo seguro para gravar no aparelho: nada de caminho vindo do servidor.
public enum BFocusFileName {
    public static func sanitize(_ name: String?, fallback: String = "download") -> String {
        func clean(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            let safe = last
                .replacingOccurrences(of: ":", with: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !safe.isEmpty, safe != ".", safe != ".." else { return nil }
            return safe
        }
        return clean(name) ?? clean(fallback) ?? "download"
    }
}
