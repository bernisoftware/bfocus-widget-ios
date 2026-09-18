import XCTest
import BFocusWidgetCore

/// Transporte falso: registra as requests e mede a concorrência.
final class FakeTransport: BFocusHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> BFocusHTTPResponse

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var active = 0
    private var peak = 0
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> BFocusHTTPResponse {
        locked {
            recorded.append(request)
            active += 1
            peak = max(peak, active)
        }
        defer { locked { active -= 1 } }
        return try await handler(request)
    }

    var requests: [URLRequest] { locked { recorded } }
    var paths: [String] { requests.compactMap { $0.url?.path } }
    var maxConcurrent: Int { locked { peak } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func ok(_ data: Any) -> BFocusHTTPResponse {
        BFocusHTTPResponse(statusCode: 200, body: Scenarios.json(["code": "OK", "data": data, "message": ""]))
    }

    static func fixture(_ name: String) -> BFocusHTTPResponse { ok(Scenarios.fixture(name)) }

    static func error(_ status: Int, _ message: String) -> BFocusHTTPResponse {
        BFocusHTTPResponse(statusCode: status, body: Scenarios.json(["code": "ERROR", "data": NSNull(), "message": message]))
    }

    static func state(latest: String?, banner: [String] = []) -> BFocusHTTPResponse {
        var fixture = Scenarios.fixture("default")
        var tickets = fixture["tickets"] as? [String: Any] ?? [:]
        tickets["latest_event_at"] = latest ?? NSNull()
        fixture["tickets"] = tickets
        var notes = fixture["release_notes"] as? [String: Any] ?? [:]
        notes["banner_ids"] = banner
        fixture["release_notes"] = notes
        return ok(fixture)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class DelegateSpy: BFocusEngineDelegate {
    var banners: [[String]] = []
    var renewed: [BFocusResolvedConfig] = []

    func engine(_ engine: BFocusEngine, showReleaseBannerWith ids: [String]) { banners.append(ids) }
    func engine(_ engine: BFocusEngine, didRenewIdentity config: BFocusResolvedConfig) { renewed.append(config) }
}

final class EngineTests: XCTestCase {
    static let launcherPath = "/api/v1/widget/launcher-state"
    static let bannerIds = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]

    @MainActor
    private func makeEngine(
        _ transport: FakeTransport,
        interval: TimeInterval = 60,
        store: BFocusKeyValueStore = BFocusMemoryStore(),
        autoBanner: Bool = true,
        provider: (@Sendable () async throws -> String)? = nil
    ) -> BFocusEngine {
        var config = Scenarios.config("min")
        config.pollIntervalSeconds = interval
        config.autoShowReleaseBanner = autoBanner
        return BFocusEngine(config: config, api: BFocusAPIClient(transport: transport), store: store, userHashProvider: provider)
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    func testFirstCallRunsAloneBeforePushAndRefresh() async {
        let transport = FakeTransport { request in
            if request.url?.path == EngineTests.launcherPath {
                try await Task.sleep(nanoseconds: 150_000_000)
                return FakeTransport.fixture("default")
            }
            return FakeTransport.ok(["ok": true])
        }
        let engine = makeEngine(transport)
        engine.start()
        let push = Task { await engine.registerPush(token: "fcm-token-1") }
        let refresh = Task { await engine.refresh() }
        let outcome = await push.value
        await refresh.value
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(transport.maxConcurrent, 1, "nada em paralelo com a primeira chamada")
        XCTAssertEqual(transport.paths, [Self.launcherPath, "/api/v1/widget/push/devices"])
        // Mesmo token de novo: não chama.
        _ = await engine.registerPush(token: "fcm-token-1")
        XCTAssertEqual(transport.requests.count, 2)
        engine.stop()
    }

    @MainActor
    func testPollsOnlyInForegroundWithWidgetClosed() async {
        let transport = FakeTransport { _ in FakeTransport.fixture("default") }
        let engine = makeEngine(transport, interval: 0.1)
        engine.start()
        await engine.waitForFirstCall()
        await pause(0.5)
        XCTAssertGreaterThanOrEqual(transport.requests.count, 3, "consulta periódica")

        engine.setWidgetOpen(true)
        // Uma consulta disparada logo antes de abrir pode terminar depois (runner lento): conta a
        // partir de quando ela assenta.
        await pause(0.15)
        let atOpen = transport.requests.count
        await pause(0.35)
        XCTAssertEqual(transport.requests.count, atOpen, "aberto não consulta")

        engine.setWidgetOpen(false)
        await engine.refresh() // junta-se à consulta disparada pelo fechar
        XCTAssertEqual(transport.requests.count, atOpen + 1, "fechar consulta na hora")

        engine.setForeground(false)
        let atBackground = transport.requests.count
        await pause(0.35)
        XCTAssertEqual(transport.requests.count, atBackground, "segundo plano não consulta")

        engine.setForeground(true)
        await engine.refresh()
        XCTAssertEqual(transport.requests.count, atBackground + 1, "voltar ao primeiro plano consulta")
        engine.stop()
    }

    @MainActor
    func testRefreshJoinsCallInFlight() async {
        let transport = FakeTransport { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return FakeTransport.fixture("default")
        }
        let engine = makeEngine(transport)
        engine.start()
        let tasks = (0..<3).map { _ in Task { await engine.refresh() } }
        for task in tasks { await task.value }
        XCTAssertEqual(transport.requests.count, 1)
        engine.stop()
    }

    @MainActor
    func testIdentityErrorRenewsHashAndRetriesOnce() async {
        let transport = FakeTransport { request in
            let header = request.value(forHTTPHeaderField: "X-bFocus-Widget-User") ?? ""
            let json = String(decoding: Data(base64Encoded: header) ?? Data(), as: UTF8.self)
            return json.contains(#""userHash":"hash-novo""#)
                ? FakeTransport.fixture("default")
                : FakeTransport.error(401, BFocusError.userHashInvalid)
        }
        let calls = Counter()
        let engine = makeEngine(transport) {
            calls.next()
            return "hash-novo"
        }
        let spy = DelegateSpy()
        engine.delegate = spy
        var errors: [String] = []
        engine.onError = { errors.append($0.code) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(errors, [], "a repetição com o hash novo passou: nada a avisar")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(engine.config.userHash, "hash-novo")
        XCTAssertEqual(spy.renewed.map(\.userHash), ["hash-novo"])
        XCTAssertNotNil(engine.lastState)
        engine.stop()
    }

    @MainActor
    func testIdentityErrorStillInvalidAfterRenewStopsThere() async {
        let transport = FakeTransport { _ in FakeTransport.error(401, BFocusError.verifiedSessionRequired) }
        let calls = Counter()
        let engine = makeEngine(transport) {
            return "hash-\(calls.next())"
        }
        var errors: [String] = []
        engine.onError = { errors.append($0.code) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(errors, [BFocusError.verifiedSessionRequired], "avisa só depois da repetição recusada")
        XCTAssertEqual(calls.count, 1, "um hash novo por chamada")
        XCTAssertEqual(transport.requests.count, 2, "uma nova tentativa só")

        // Próximo ciclo: tenta de novo (outro hash), mas o mesmo código não é avisado outra vez.
        await engine.refresh()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(errors, [BFocusError.verifiedSessionRequired])
        engine.stop()
    }

    @MainActor
    func testIdentityErrorWithoutProviderOnlyReports() async {
        let transport = FakeTransport { _ in FakeTransport.error(401, BFocusError.userHashInvalid) }
        let engine = makeEngine(transport)
        var errors: [BFocusError] = []
        engine.onError = { errors.append($0) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(errors.map(\.code), [BFocusError.userHashInvalid], "sem provider: na hora")
        XCTAssertEqual(transport.requests.count, 1)
        await engine.refresh()
        await engine.refresh()
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(errors.count, 1, "mesmo código a cada ciclo: um aviso só")
        engine.stop()
    }

    @MainActor
    func testProviderFailureIsReported() async {
        struct Boom: Error {}
        let transport = FakeTransport { _ in FakeTransport.error(401, BFocusError.userHashInvalid) }
        let engine = makeEngine(transport) { throw Boom() }
        var errors: [String] = []
        engine.onError = { errors.append($0.code) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(errors, [BFocusError.userHashProviderFailed, BFocusError.userHashInvalid])
        XCTAssertEqual(transport.requests.count, 1)
        engine.stop()
    }

    @MainActor
    func testOther4xxReportedOncePerCodeAndRearmedAfterSuccess() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            switch calls.next() {
            case 1, 2: return FakeTransport.error(403, "WIDGET_ORIGIN_NOT_ALLOWED")
            case 3: return BFocusHTTPResponse(statusCode: 404, body: Data("<html>".utf8))
            case 4: return FakeTransport.fixture("default")
            default: return FakeTransport.error(403, "WIDGET_ORIGIN_NOT_ALLOWED")
            }
        }
        let engine = makeEngine(transport)
        var errors: [String] = []
        engine.onError = { errors.append($0.code) }
        engine.start()
        await engine.waitForFirstCall()
        await engine.refresh() // 403 de novo: não repete o aviso
        await engine.refresh() // 404 sem envelope: HTTP_404
        XCTAssertEqual(errors, ["WIDGET_ORIGIN_NOT_ALLOWED", "HTTP_404"])
        await engine.refresh() // sucesso rearma
        await engine.refresh() // 403 volta a ser avisado
        XCTAssertEqual(errors, ["WIDGET_ORIGIN_NOT_ALLOWED", "HTTP_404", "WIDGET_ORIGIN_NOT_ALLOWED"])
        engine.stop()
    }

    @MainActor
    func testNetworkErrorsAnd5xxAreSilent() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            if calls.next() == 1 { throw URLError(.notConnectedToInternet) }
            return BFocusHTTPResponse(statusCode: 503, body: Data("<html>".utf8))
        }
        let engine = makeEngine(transport)
        var errors: [BFocusError] = []
        engine.onError = { errors.append($0) }
        engine.start()
        await engine.waitForFirstCall()
        await engine.refresh()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(engine.lastState)
        XCTAssertEqual(engine.releaseNotes, .placeholder)
        engine.stop()
    }

    func testCallTimeout() async {
        let transport = FakeTransport { _ in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return FakeTransport.fixture("default")
        }
        let started = Date()
        let outcome = await BFocusAPIClient(transport: transport, timeout: 0.2).launcherState(Scenarios.config("min"))
        if case .failure(let status, let code) = outcome {
            XCTAssertNil(status)
            XCTAssertNil(code)
        } else {
            XCTFail("esperava falha por tempo")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    @MainActor
    func testBannerOpensOnceAndAgainAfterDone() async {
        let transport = FakeTransport { _ in FakeTransport.fixture("banner") }
        let engine = makeEngine(transport)
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.start()
        await engine.waitForFirstCall()
        await engine.refresh()
        XCTAssertEqual(spy.banners, [Self.bannerIds], "não reabre o mesmo conjunto aberto")
        XCTAssertEqual(engine.releaseNotes.label, "v4.2.0")
        XCTAssertTrue(engine.releaseNotes.dot)

        engine.releaseBannerDidFinish()
        await engine.refresh()
        XCTAssertEqual(transport.requests.count, 3, "rn:done consulta de novo")
        XCTAssertEqual(spy.banners.count, 2, "ainda pendente no servidor: abre de novo")
        engine.stop()
    }

    @MainActor
    func testStaleResponseDoesNotReopenBannerAfterDone() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            switch calls.next() {
            case 1:
                return FakeTransport.state(latest: nil, banner: EngineTests.bannerIds)
            case 2:
                // Consulta que saiu ANTES da ciência e volta depois dela.
                try await Task.sleep(nanoseconds: 200_000_000)
                return FakeTransport.state(latest: nil, banner: EngineTests.bannerIds)
            default:
                return FakeTransport.state(latest: nil, banner: [])
            }
        }
        let engine = makeEngine(transport)
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(spy.banners.count, 1)

        let slow = Task { await engine.refresh() }
        await pause(0.05)
        engine.releaseBannerDidFinish()
        await slow.value
        for _ in 0..<40 where transport.requests.count < 3 { await pause(0.025) }
        await engine.refresh()
        XCTAssertGreaterThanOrEqual(transport.requests.count, 3)
        XCTAssertEqual(spy.banners.count, 1, "resposta antiga não reabre o banner")
        XCTAssertEqual(engine.releaseNotes.bannerIds, [])
        engine.stop()
    }

    @MainActor
    func testBannerRespectsAutoShowOff() async {
        let transport = FakeTransport { _ in FakeTransport.fixture("banner") }
        let engine = makeEngine(transport, autoBanner: false)
        let spy = DelegateSpy()
        engine.delegate = spy
        var notes: [BFocusReleaseNotesState] = []
        engine.onReleaseNotesChanged = { notes.append($0) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertTrue(spy.banners.isEmpty)
        XCTAssertEqual(notes.last?.bannerIds, Self.bannerIds, "a fila segue disponível no callback")
        engine.stop()
    }

    @MainActor
    func testBadgeFromLauncherStateAndEmbed() async {
        let calls = Counter()
        let transport = FakeTransport { _ in
            calls.next() == 1
                ? FakeTransport.state(latest: "2026-09-01T12:00:00+00:00")
                : FakeTransport.state(latest: "2026-09-01T12:05:00+00:00")
        }
        let store = BFocusMemoryStore()
        let engine = makeEngine(transport, store: store)
        var labels: [String] = []
        engine.onBadgeChanged = { labels.append($0) }
        engine.start()
        await engine.waitForFirstCall()
        XCTAssertEqual(engine.badge.label, "", "primeira visita não acende")
        XCTAssertEqual(store.string(forKey: engine.config.lastSeenStorageKey), "2026-09-01T12:00:00+00:00")

        await engine.refresh()
        XCTAssertEqual(labels, ["•"])

        engine.setWidgetOpen(true)
        engine.handle(.unread(count: 4))
        engine.handle(.seen(latestEventAt: "2026-09-01T12:05:00+00:00"))
        engine.handle(.unread(count: 0))
        engine.setWidgetOpen(false)
        await engine.refresh()
        XCTAssertEqual(labels, ["•", "4", ""])
        XCTAssertEqual(engine.badge.lastSeen, "2026-09-01T12:05:00+00:00")
        engine.stop()
    }

    @MainActor
    func testBrandingAndErrorsFromEmbed() {
        let engine = makeEngine(FakeTransport { _ in FakeTransport.fixture("default") })
        var colors: [String] = []
        var errors: [String] = []
        engine.onPrimaryColorChanged = { colors.append($0) }
        engine.onError = { errors.append($0.code) }
        engine.handle(.branding(primaryColor: "#123456"))
        engine.handle(.releaseNotesBranding(primaryColor: "#123456"))
        engine.handle(.branding(primaryColor: nil))
        engine.handle(.error(BFocusError(code: BFocusError.configFailed)))
        engine.handle(.openExternal(URL(string: "https://example.com")!))
        XCTAssertEqual(colors, ["#123456"])
        XCTAssertEqual(errors, [BFocusError.configFailed])
        XCTAssertEqual(engine.primaryColor, "#123456")
    }

    @MainActor
    func testLogoutUnregistersPushAndClearsState() async throws {
        let transport = FakeTransport { request in
            request.url?.path == EngineTests.launcherPath ? FakeTransport.fixture("default") : FakeTransport.ok(["ok": true])
        }
        let store = BFocusMemoryStore()
        let engine = makeEngine(transport, store: store)
        engine.start()
        _ = await engine.registerPush(token: "tok-1")
        XCTAssertEqual(engine.storedPushToken, "tok-1")
        await engine.logout()
        XCTAssertEqual(transport.paths, [Self.launcherPath, "/api/v1/widget/push/devices", "/api/v1/widget/push/devices/unregister"])
        let body = try JSONSerialization.jsonObject(with: transport.requests.last?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["token": "tok-1"])
        XCTAssertNil(engine.storedPushToken)
        XCTAssertNil(engine.badge.lastSeen)
        XCTAssertTrue(engine.isStopped)
        let nothing = await engine.unregisterPush()
        XCTAssertNil(nothing, "sem token, nada a cancelar")
    }

    @MainActor
    func testStopDiscardsLateResponse() async {
        let transport = FakeTransport { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return FakeTransport.fixture("banner")
        }
        let engine = makeEngine(transport)
        let spy = DelegateSpy()
        engine.delegate = spy
        engine.start()
        engine.stop()
        await pause(0.3)
        XCTAssertNil(engine.lastState)
        XCTAssertTrue(spy.banners.isEmpty)
    }
}
