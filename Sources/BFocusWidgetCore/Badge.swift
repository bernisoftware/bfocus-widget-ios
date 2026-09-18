import Foundation

/// Armazenamento chave-valor persistente (injetável nos testes).
public protocol BFocusKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// Padrão: `UserDefaults` (o `last_seen` e o token de push sobrevivem ao app fechar).
public final class BFocusUserDefaultsStore: BFocusKeyValueStore {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Em memória: testes e integradores que não querem persistir nada.
public final class BFocusMemoryStore: BFocusKeyValueStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) {
        values = initial
    }

    public func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

/// Datas ISO 8601 comparadas como INSTANTE (não como texto): `07:00-03:00` == `10:00+00:00`.
public enum BFocusInstant {
    /// Aceita `YYYY-MM-DD[T| ]HH:MM[:SS[.fração]][Z|±HH[:MM]]`. Sem fuso = UTC.
    /// Parser próprio porque o `ISO8601DateFormatter` falha com os microssegundos do Python.
    public static func parse(_ text: String) -> Date? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var i = 0

        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func number(_ count: Int) -> Int? {
            guard i + count <= s.count else { return nil }
            var value = 0
            for k in 0..<count {
                let c = s[i + k]
                guard isDigit(c) else { return nil }
                value = value * 10 + Int(c - 48)
            }
            i += count
            return value
        }
        func take(_ c: Character) -> Bool {
            guard i < s.count, s[i] == c.asciiValue! else { return false }
            i += 1
            return true
        }

        guard let year = number(4), take("-"), let month = number(2), take("-"), let day = number(2) else {
            return nil
        }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        if take("T") || take("t") || take(" ") {
            guard let h = number(2), take(":"), let m = number(2) else { return nil }
            hour = h
            minute = m
            if take(":") {
                guard let sec = number(2) else { return nil }
                second = sec
                if take(".") || take(",") {
                    let start = i
                    while i < s.count, isDigit(s[i]) { i += 1 }
                    guard i > start else { return nil }
                    fraction = Double("0." + String(decoding: s[start..<i], as: UTF8.self)) ?? 0
                }
            }
        }
        var offset = 0
        if i < s.count {
            if take("Z") || take("z") {
                offset = 0
            } else if s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") {
                let sign = s[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = number(2) else { return nil }
                var om = 0
                if take(":") {
                    guard let m = number(2) else { return nil }
                    om = m
                } else if let m = number(2) {
                    om = m
                }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        guard i == s.count,
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction - TimeInterval(offset))
    }

    /// `a` é posterior a `b`? Se alguma não for data válida, compara o texto (como o web).
    public static func isAfter(_ a: String, _ b: String) -> Bool {
        if let da = parse(a), let db = parse(b) { return da > db }
        return a > b
    }
}

/// Modelo do "•" do botão, idêntico ao `widget.js` (`scenarios.badge`).
///
/// - `applyState(latest)` só vale com o widget FECHADO. Nulo: nada. Sem `last_seen`: grava e
///   não acende. `latest > last_seen` (como instante): `•`.
/// - `applyUnread(count)`: label = count (`99+` acima de 99; vazio em 0).
/// - `applySeen(ts)`: `last_seen` = ts.
/// Não é thread-safe: use sempre da mesma thread (a engine usa a main).
public final class BFocusBadgeModel {
    public static let dot = "•"

    public static func storageKey(publishableKey: String, userExternalId: String, customerExternalId: String) -> String {
        "bf:lastSeen:\(publishableKey):\(userExternalId):\(customerExternalId)"
    }

    public static func label(forUnread count: Int) -> String {
        if count > 99 { return "99+" }
        return count > 0 ? String(count) : ""
    }

    public let store: BFocusKeyValueStore
    public let storageKey: String
    public var onChange: ((String) -> Void)?

    public private(set) var label: String {
        didSet { if label != oldValue { onChange?(label) } }
    }

    public private(set) var isOpen = false

    public init(store: BFocusKeyValueStore, storageKey: String, label: String = "") {
        self.store = store
        self.storageKey = storageKey
        self.label = label
    }

    public var lastSeen: String? {
        guard let value = store.string(forKey: storageKey), !value.isEmpty else { return nil }
        return value
    }

    public func applyState(latestEventAt latest: String?) {
        // Aberto, quem manda no badge é o embed (bfocus:unread/seen).
        guard !isOpen else { return }
        guard let latest, !latest.isEmpty else { return }
        guard let seen = lastSeen else {
            // Primeira visita: só a base, sem acender.
            store.setString(latest, forKey: storageKey)
            return
        }
        if BFocusInstant.isAfter(latest, seen) { label = Self.dot }
    }

    public func applyUnread(_ count: Int) {
        label = Self.label(forUnread: count)
    }

    public func applySeen(_ latest: String?) {
        guard let latest, !latest.isEmpty else { return }
        store.setString(latest, forKey: storageKey)
    }

    public func open() { isOpen = true }

    public func close() { isOpen = false }

    /// Logout: apaga a base e o label.
    public func reset() {
        isOpen = false
        store.setString(nil, forKey: storageKey)
        label = ""
    }
}
