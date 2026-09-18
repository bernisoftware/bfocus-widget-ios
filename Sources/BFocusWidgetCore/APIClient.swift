import Foundation

/// Resposta crua de uma chamada HTTP.
public struct BFocusHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Transporte HTTP injetável (testes usam um falso; o padrão é `URLSession`).
public protocol BFocusHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BFocusHTTPResponse
}

public struct BFocusURLSessionTransport: BFocusHTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> BFocusHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return BFocusHTTPResponse(statusCode: http.statusCode, body: data)
    }
}

/// Erro reportado ao integrador (`onError`).
public struct BFocusError: Error, Equatable, Sendable, CustomStringConvertible {
    public static let userHashInvalid = "WIDGET_USER_HASH_INVALID"
    public static let verifiedSessionRequired = "WIDGET_VERIFIED_SESSION_REQUIRED"
    public static let configFailed = "WIDGET_CONFIG_FAILED"
    /// O `userHashProvider` do integrador lançou erro.
    public static let userHashProviderFailed = "WIDGET_USER_HASH_PROVIDER_FAILED"

    static let identityCodes: Set<String> = [userHashInvalid, verifiedSessionRequired]

    public var code: String
    public var detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var isIdentityError: Bool { Self.identityCodes.contains(code) }

    public var description: String { detail.map { "\(code): \($0)" } ?? code }
}

/// Resultado de uma chamada ao bFocus.
public enum BFocusCallOutcome<Value> {
    case success(Value)
    /// 401 `WIDGET_USER_HASH_INVALID` / `WIDGET_VERIFIED_SESSION_REQUIRED`: vira `onError`.
    case identityError(BFocusError)
    /// Rede, tempo esgotado, 5xx, outros 4xx: ignorado em silêncio (tenta no próximo ciclo).
    case failure(status: Int?, code: String?)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

extension BFocusCallOutcome: Sendable where Value: Sendable {}

/// Montagem das requests (idênticas a `scenarios.launcherStateRequest` e `push.*`).
public enum BFocusRequests {
    /// Tempo máximo por chamada (BRIEF §4.1).
    public static let timeout: TimeInterval = 15

    /// Os cinco headers de toda chamada do pacote.
    public static func headers(_ config: BFocusResolvedConfig) -> [String: String] {
        [
            "Content-Type": "application/json",
            "X-bFocus-Widget-Key": config.publishableKey,
            "X-bFocus-Widget-User": config.userBase64,
            "X-bFocus-Parent-Origin": config.parentOrigin,
            "X-bFocus-Client": config.client,
        ]
    }

    public static func launcherState(_ config: BFocusResolvedConfig) -> URLRequest {
        var query: [String] = []
        if let product = config.product, !product.isEmpty {
            query.append("product=" + BFocusURLEncoding.component(product))
        }
        if let audience = config.audience {
            query.append("audience=" + BFocusURLEncoding.component(audience.rawValue))
        }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return post(config.apiBase + "/api/v1/widget/launcher-state" + suffix, body: "{}", config: config)
    }

    public static func pushRegister(_ config: BFocusResolvedConfig, token: String, platform: String) -> URLRequest {
        let body = BFocusJSONText.object([
            ("token", BFocusJSONText.string(token)),
            ("platform", BFocusJSONText.string(platform)),
            // Mesmo valor da origem (bundle id em minúsculas), que é o que está cadastrado.
            ("app_id", BFocusJSONText.string(config.appId.lowercased())),
        ])
        return post(config.apiBase + "/api/v1/widget/push/devices", body: body, config: config)
    }

    public static func pushUnregister(_ config: BFocusResolvedConfig, token: String) -> URLRequest {
        let body = BFocusJSONText.object([("token", BFocusJSONText.string(token))])
        return post(config.apiBase + "/api/v1/widget/push/devices/unregister", body: body, config: config)
    }

    static func post(_ urlString: String, body: String, config: BFocusResolvedConfig) -> URLRequest {
        // apiBase já foi validada no resolved(); os componentes variáveis vão codificados.
        var request = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        for (name, value) in headers(config) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(body.utf8)
        return request
    }
}

/// Cliente HTTP do pacote (launcher-state e push).
public struct BFocusAPIClient: Sendable {
    public let transport: BFocusHTTPTransport
    public let timeout: TimeInterval

    public init(
        transport: BFocusHTTPTransport = BFocusURLSessionTransport(),
        timeout: TimeInterval = BFocusRequests.timeout
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func launcherState(_ config: BFocusResolvedConfig) async -> BFocusCallOutcome<BFocusLauncherState> {
        await call(BFocusRequests.launcherState(config)) { try BFocusLauncherState.decodeEnvelope($0) }
    }

    public func registerPush(_ config: BFocusResolvedConfig, token: String, platform: String) async -> BFocusCallOutcome<Void> {
        await call(BFocusRequests.pushRegister(config, token: token, platform: platform)) { _ in () }
    }

    public func unregisterPush(_ config: BFocusResolvedConfig, token: String) async -> BFocusCallOutcome<Void> {
        await call(BFocusRequests.pushUnregister(config, token: token)) { _ in () }
    }

    func call<T>(_ request: URLRequest, decode: (Data) throws -> T) async -> BFocusCallOutcome<T> {
        let transport = self.transport
        let response: BFocusHTTPResponse
        do {
            // O timeoutInterval do URLRequest é de ociosidade; o limite de 15 s é por chamada.
            response = try await BFocusTimeout.run(seconds: timeout) { try await transport.send(request) }
        } catch {
            return .failure(status: nil, code: nil)
        }
        let status = response.statusCode
        if (200..<300).contains(status) {
            do {
                return .success(try decode(response.body))
            } catch {
                return .failure(status: status, code: nil)
            }
        }
        let error = BFocusEnvelope.error(from: response.body)
        if let error, error.isIdentityError {
            return .identityError(error)
        }
        return .failure(status: status, code: error?.code)
    }
}

/// Envelope `{code, data, message}` da API; em erro o código de máquina vem em `message`
/// (ou em `detail`, quando o erro sai direto do FastAPI).
enum BFocusEnvelope {
    static func error(from body: Data) -> BFocusError? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let message = object["message"] as? String, !message.isEmpty {
            return BFocusError(code: message, detail: object["detail"] as? String)
        }
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return BFocusError(code: detail)
        }
        if let detail = object["detail"] as? [String: Any],
           let code = (detail["code"] as? String) ?? (detail["message"] as? String) {
            return BFocusError(code: code, detail: detail["detail"] as? String)
        }
        return nil
    }
}

enum BFocusTimeout {
    /// Corre `operation` com prazo; estourou = `URLError(.timedOut)` e a chamada é cancelada.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.unknown) }
            return first
        }
    }
}
