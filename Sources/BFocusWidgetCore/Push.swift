import Foundation

/// Push do bFocus (FCM HTTP v1). O pacote NÃO depende do Firebase: o app do integrador entrega
/// o token FCM e o `userInfo` da notificação.
public enum BFocusPush {
    /// `platform` do registro no iOS.
    public static let defaultPlatform = "ios"

    /// Para onde o widget navega, ou `nil` se a notificação não é do bFocus (`scenarios.push.handle`).
    ///
    /// Formato: `data = {bfocus: "1", type, ticket_id, conversation_id?}`. No iOS esses campos
    /// chegam no topo do `userInfo`. Também aceita `bfocus` como objeto (ou JSON em string).
    public static func navigation(for data: [AnyHashable: Any]) -> BFocusNavigation? {
        var fields = data
        if let nested = nestedObject(data["bfocus"]) {
            fields = nested
        } else if !isMarker(data["bfocus"]) {
            return nil
        }

        let ticketId = string(fields["ticket_id"])
        switch string(fields["type"]) {
        case "ticket.reply", "ticket.status":
            if let ticketId { return BFocusNavigation(view: "ticket", ticketId: ticketId) }
            return BFocusNavigation(view: "list")
        case "chat.message":
            if let conversationId = string(fields["conversation_id"]) {
                return BFocusNavigation(view: "chat", conversationId: conversationId)
            }
            if let ticketId { return BFocusNavigation(view: "ticket", ticketId: ticketId) }
            return BFocusNavigation(view: "chat")
        default:
            // Tipo novo (o contrato é aditivo): ainda é do bFocus, abre a lista.
            return BFocusNavigation(view: "list")
        }
    }

    static func isMarker(_ value: Any?) -> Bool {
        switch value {
        case let text as String:
            return text == "1" || text.lowercased() == "true"
        case let number as NSNumber:
            return number.intValue == 1
        default:
            return false
        }
    }

    static func nestedObject(_ value: Any?) -> [AnyHashable: Any]? {
        if let object = value as? [AnyHashable: Any] { return object }
        if let text = value as? String, text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
