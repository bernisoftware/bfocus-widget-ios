#if os(macOS)
import Foundation
import XCTest
import BFocusWidgetCore

/// Sobe `node widgets-native/conformance/mock-server.mjs 0` e lê a porta na 1ª linha.
/// Fora do monorepo (espelho público) o script não existe e os testes são pulados; aponte
/// `BFOCUS_CONFORMANCE_DIR` para a pasta `conformance` para rodar mesmo assim.
final class MockServer {
    let baseURL: URL
    private let process = Process()

    init() throws {
        guard let node = Self.nodeURL() else { throw XCTSkip("node não encontrado no PATH") }
        guard let script = Self.scriptURL() else { throw XCTSkip("mock-server.mjs não encontrado (fora do monorepo)") }
        let output = Pipe()
        process.executableURL = node
        process.arguments = [script.path, "0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let line = Self.firstLine(of: output.fileHandleForReading, timeout: 15)
        guard let range = line.range(of: "http://"),
              let url = URL(string: String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw XCTSkip("mock-server não respondeu: \(line)")
        }
        baseURL = url
    }

    func stop() {
        // Sem waitUntilExit: na main actor de um teste async ele nunca recebe o término e trava.
        // O node sai no SIGTERM; não precisamos esperar.
        guard process.isRunning else { return }
        process.terminate()
    }

    func post(_ path: String, _ body: Any? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        _ = try await URLSession.shared.data(for: request)
    }

    func log() async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("__log"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func scriptURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["BFOCUS_CONFORMANCE_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("mock-server.mjs")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // Tests/BFocusWidgetTests/<arquivo> → ios → widgets-native/conformance/mock-server.mjs
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("conformance/mock-server.mjs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func nodeURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let node = env["NODE"], FileManager.default.isExecutableFile(atPath: node) { return URL(fileURLWithPath: node) }
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("node")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private final class Box: @unchecked Sendable { var text = "" }

    private static func firstLine(of handle: FileHandle, timeout: TimeInterval) -> String {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var buffer = Data()
            while !buffer.contains(0x0A) {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            box.text = String(decoding: buffer, as: UTF8.self)
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        return box.text.split(separator: "\n").first.map(String.init) ?? ""
    }
}

/// Cliente real (URLSession) contra o servidor simulado: cenários default, banner e identity_error.
final class MockServerIntegrationTests: XCTestCase {
    private func startServer() throws -> MockServer {
        let server = try MockServer()
        addTeardownBlock { server.stop() }
        return server
    }

    private func config(_ server: MockServer, userHash: String? = nil) throws -> BFocusResolvedConfig {
        try BFocusConfig(
            publishableKey: "bf_pk_test_123",
            appId: "com.empresa.erp",
            user: BFocusUser(externalId: "USR-1"),
            customer: BFocusCustomer(externalId: "ACME-1"),
            userHash: userHash,
            apiBaseUrl: server.baseURL,
            embedBaseUrl: server.baseURL.appendingPathComponent("v1")
        ).resolved(defaultAppId: nil, deviceLocale: .ptBR)
    }

    private func requests(_ server: MockServer) async throws -> [[String: Any]] {
        try await server.log()["requests"] as? [[String: Any]] ?? []
    }

    private func assertHeaders(_ request: [String: Any], _ config: BFocusResolvedConfig, file: StaticString = #filePath, line: UInt = #line) {
        // O Node entrega os nomes em minúsculas.
        let headers = request["headers"] as? [String: String] ?? [:]
        XCTAssertEqual(headers["content-type"], "application/json", file: file, line: line)
        XCTAssertEqual(headers["x-bfocus-widget-key"], "bf_pk_test_123", file: file, line: line)
        XCTAssertEqual(headers["x-bfocus-widget-user"], config.userBase64, file: file, line: line)
        XCTAssertEqual(headers["x-bfocus-parent-origin"], "app://com.empresa.erp", file: file, line: line)
        XCTAssertEqual(headers["x-bfocus-client"], "ios/0.1.0", file: file, line: line)
    }

    func testDefaultScenario() async throws {
        let server = try startServer()
        let config = try config(server)
        let outcome = await BFocusAPIClient().launcherState(config)
        guard case .success(let state) = outcome else { return XCTFail("esperava sucesso: \(outcome)") }
        XCTAssertEqual(state.primaryColor, "#0EA5E9")
        XCTAssertEqual(state.tickets.openCount, 2)
        XCTAssertEqual(state.tickets.latestEventAt, "2026-09-01T12:00:00+00:00")
        XCTAssertEqual(BFocusReleaseNotesState(payload: state.releaseNotes).label, "v4.2.0")

        let logged = try await requests(server)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?["method"] as? String, "POST")
        XCTAssertEqual(logged.first?["path"] as? String, "/api/v1/widget/launcher-state")
        XCTAssertEqual(logged.first?["body"] as? String, "{}")
        if let first = logged.first { assertHeaders(first, config) }
    }

    @MainActor
    func testBannerScenarioThroughEngine() async throws {
        let server = try startServer()
        try await server.post("__scenario", ["name": "banner"])
        let engine = BFocusEngine(config: try config(server), store: BFocusMemoryStore())
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(spy.banners, [["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]])
        XCTAssertEqual(engine.releaseNotes, BFocusReleaseNotesState(
            label: "v4.2.0", dot: true, bannerIds: spy.banners.first ?? [], productColor: "#22C55E"
        ))
        XCTAssertNil(engine.badge.lastSeen, "latest nulo não grava")
        engine.stop()
    }

    @MainActor
    func testIdentityErrorScenarioThroughEngine() async throws {
        let server = try startServer()
        try await server.post("__scenario", ["name": "identity_error"])
        let config = try config(server, userHash: "hash-velho")
        let calls = Counter()
        let engine = BFocusEngine(config: config, store: BFocusMemoryStore()) {
            calls.next()
            return "hash-novo"
        }
        var errors: [String] = []
        engine.onError = { errors.append($0.code) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(errors, [BFocusError.userHashInvalid], "avisa uma vez, depois da repetição recusada")
        XCTAssertEqual(calls.count, 1)

        let logged = try await requests(server)
        XCTAssertEqual(logged.count, 2, "uma nova tentativa com o hash novo")
        let users = logged.compactMap { ($0["headers"] as? [String: String])?["x-bfocus-widget-user"] }
            .map { String(decoding: Data(base64Encoded: $0) ?? Data(), as: UTF8.self) }
        XCTAssertTrue(users.first?.contains(#""userHash":"hash-velho""#) ?? false)
        XCTAssertTrue(users.last?.contains(#""userHash":"hash-novo""#) ?? false)
        engine.stop()
    }

    @MainActor
    func testPushRegisterAndUnregister() async throws {
        let server = try startServer()
        let config = try config(server)
        let engine = BFocusEngine(config: config, store: BFocusMemoryStore())
        engine.start()
        let registered = await engine.registerPush(token: "fcm-token-1")
        XCTAssertTrue(registered.isSuccess)
        let unregistered = await engine.unregisterPush()
        XCTAssertEqual(unregistered?.isSuccess, true)

        let logged = try await requests(server)
        XCTAssertEqual(logged.map { $0["path"] as? String ?? "" }, [
            "/api/v1/widget/launcher-state",
            "/api/v1/widget/push/devices",
            "/api/v1/widget/push/devices/unregister",
        ])
        for request in logged { assertHeaders(request, config) }
        func body(_ index: Int) throws -> NSDictionary? {
            let text = logged[index]["body"] as? String ?? ""
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        }
        XCTAssertEqual(try body(1), ["token": "fcm-token-1", "platform": "ios", "app_id": "com.empresa.erp"])
        XCTAssertEqual(try body(2), ["token": "fcm-token-1"])
        engine.stop()
    }
}
#endif
