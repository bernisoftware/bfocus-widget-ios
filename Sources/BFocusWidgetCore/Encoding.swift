import Foundation

/// Codificação de componentes de URL.
public enum BFocusURLEncoding {
    /// RFC 3986: só `[A-Za-z0-9-._~]` passam; o resto vira `%XX` (maiúsculo) sobre os bytes
    /// UTF-8. Igual ao `enc()` do generate.mjs; espaço vira `%20`, nunca `+`.
    /// Não usamos `addingPercentEncoding` porque o conjunto dele deixa passar `:` `/` `+` etc.
    public static func component(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isUnreserved(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += "%" + hex(byte)
            }
        }
        return out
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    static func hex(_ byte: UInt8) -> String {
        String([hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
    }
}

/// JSON escrito à mão, byte a byte igual ao `JSON.stringify` do JS.
///
/// Não dá para usar `JSONSerialization`/`JSONEncoder`: eles escapam `/` (`https:\/\/…`) e não
/// garantem a ordem das chaves, e o base64 do usuário tem de ser idêntico ao do web.
enum BFocusJSONText {
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + BFocusURLEncoding.hex(UInt8(scalar.value)).lowercased()
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Objeto com as chaves NA ORDEM dada; os valores já são fragmentos JSON.
    static func object(_ members: [(String, String)]) -> String {
        "{" + members.map { string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }
}

/// Literal de string JSON (igual ao `JSON.stringify`), seguro para montar scripts JS.
public enum BFocusJSON {
    public static func quote(_ value: String) -> String { BFocusJSONText.string(value) }
}

/// Payload do usuário (parâmetro `user=` e header `X-bFocus-Widget-User`).
public enum BFocusUserPayload {
    /// JSON compacto nesta ordem: externalId, name, email, phone, userHash, locale, customer{…}.
    /// Campos nulos ou vazios somem; `locale` vai sempre.
    public static func json(
        user: BFocusUser,
        customer: BFocusCustomer,
        userHash: String?,
        locale: BFocusLocale
    ) -> String {
        var members: [(String, String)] = []
        add(&members, "externalId", user.externalId)
        add(&members, "name", user.name)
        add(&members, "email", user.email)
        add(&members, "phone", user.phone)
        add(&members, "userHash", userHash)
        members.append(("locale", BFocusJSONText.string(locale.rawValue)))

        var customerMembers: [(String, String)] = []
        add(&customerMembers, "externalId", customer.externalId)
        add(&customerMembers, "name", customer.name)
        add(&customerMembers, "document", customer.document)
        add(&customerMembers, "email", customer.email)
        add(&customerMembers, "phone", customer.phone)
        add(&customerMembers, "website", customer.website)
        members.append(("customer", BFocusJSONText.object(customerMembers)))

        return BFocusJSONText.object(members)
    }

    /// Base64 padrão (com `+ / =`) sobre os bytes UTF-8; o embed decodifica com `atob`.
    public static func base64(ofJSON json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    private static func add(_ members: inout [(String, String)], _ key: String, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        members.append((key, BFocusJSONText.string(value)))
    }
}
