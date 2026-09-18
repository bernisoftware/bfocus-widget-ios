#if canImport(UIKit) && os(iOS)
import UIKit
import WebKit
import XCTest
@testable import BFocusWidget
import BFocusWidgetCore

/// Ponte REAL (WKWebView + BFocusWebHost) contra o embed simulado (`mock-embed.html`, `script=all`).
///
/// O servidor simulado roda no Mac (o simulador enxerga o 127.0.0.1 dele). Rode
/// `scripts/test-simulator.sh`: ele sobe o servidor e passa `BFOCUS_MOCK_URL` ao processo de teste
/// (prefixo TEST_RUNNER_ do xcodebuild). Sem a variável, os testes são pulados.
final class SimulatorBridgeTests: XCTestCase {
    private func mockBase() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["BFOCUS_MOCK_URL"], let url = URL(string: raw) else {
            throw XCTSkip("BFOCUS_MOCK_URL ausente: rode scripts/test-simulator.sh")
        }
        return url
    }

    private func post(_ base: URL, _ path: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    private func log(_ base: URL) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("__log"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func config(_ base: URL) -> BFocusResolvedConfig {
        BFocusResolvedConfig(
            publishableKey: "bf_pk_test_123",
            appId: "com.empresa.erp",
            user: BFocusUser(externalId: "USR-1"),
            customer: BFocusCustomer(externalId: "ACME-1"),
            apiBase: base.absoluteString,
            embedBase: base.absoluteString + "/v1"
        )
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("tempo esgotado: \(what)")
                throw XCTSkip("abortado")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitForLog(_ base: URL, _ what: String, _ condition: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        while true {
            let current = try await log(base)
            if condition(current) { return current }
            if Date() > deadline {
                XCTFail("tempo esgotado: \(what) — \(current)")
                return current
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Janela para a WebView ter tamanho e timers normais.
    @MainActor
    private func attach(_ webView: WKWebView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        webView.frame = root.view.bounds
        root.view.addSubview(webView)
        window.isHidden = false
        return window
    }

    @MainActor
    func testTicketsScriptAndHostCommands() async throws {
        let base = try mockBase()
        try await post(base, "__reset")
        let config = config(base)
        let host = BFocusWebHost(allowedOrigin: try XCTUnwrap(config.embedOrigin))
        var received: [BFocusHostMessage] = []
        var external: [URL] = []
        var downloads: [(URL, String)] = []
        host.onMessage = { received.append($0) }
        host.openExternal = { external.append($0) }
        host.onDownloadRequest = { downloads.append(($0, $1)) }
        let window = attach(host.webView)
        defer { window.isHidden = true; host.tearDown() }

        let url = try XCTUnwrap(URL(string: BFocusEmbedURL.string(for: config, page: .tickets) + "&script=all"))
        host.load(url)
        let expected = Scenarios.mockScript("tickets")
        try await waitUntil("mockEmbedScript.tickets") { received.count >= expected.count }

        // Sequência recebida = mockEmbedScript.tickets, na ordem.
        XCTAssertEqual(received.map(\.type), expected.map { $0["type"] as? String ?? "" })
        let origin = base.absoluteString
        XCTAssertEqual(received, [
            .ready(hp: 1, widget: "tickets", view: nil),
            .branding(primaryColor: "#123456"),
            .unread(count: 3),
            .seen(latestEventAt: "2026-09-01T10:05:00+00:00"),
            .openExternal(URL(string: "https://example.com/docs")!),
            .download(url: URL(string: origin + "/files/manual.pdf")!, filename: "manual.pdf"),
            .error(BFocusError(code: "WIDGET_USER_HASH_INVALID")),
            .close,
        ])
        XCTAssertTrue(host.isReady)

        // Pacote → embed: bfocus:open, bfocus:close, bfocus:navigate chegam em /__log (received).
        host.send(.open)
        host.send(.close)
        host.send(.navigate(BFocusNavigation(view: "ticket", ticketId: "t-1")))
        let afterSend = try await waitForLog(base, "received x3") { ($0["received"] as? [Any])?.count ?? 0 >= 3 }
        let got = (afterSend["received"] as? [[String: Any]] ?? []).map(NSDictionary.init(dictionary:))
        let want: [[String: Any]] = [
            ["type": "bfocus:open"],
            ["type": "bfocus:close"],
            ["type": "bfocus:navigate", "payload": ["view": "ticket", "ticketId": "t-1"]],
        ]
        XCTAssertEqual(got, want.map(NSDictionary.init(dictionary:)))

        // Navegação travada: link para outra origem não sai da WebView, vai ao navegador do sistema.
        _ = try await host.webView.evaluateJavaScript("document.getElementById('link-external').click(); 1")
        try await waitUntil("openExternal do link", timeout: 5) { !external.isEmpty }
        XCTAssertEqual(external, [URL(string: "https://example.com/external")!])
        XCTAssertEqual(host.webView.url?.path, "/v1/embed.html")

        // <a download>: vira download do pacote, sem navegar.
        _ = try await host.webView.evaluateJavaScript("document.getElementById('link-download').click(); 1")
        try await waitUntil("download do <a download>", timeout: 5) { !downloads.isEmpty }
        XCTAssertEqual(downloads.first?.0, URL(string: origin + "/files/manual.pdf"))
        XCTAssertEqual(downloads.first?.1, "manual.pdf")
        XCTAssertEqual(host.webView.url?.path, "/v1/embed.html")

        // Iframe de OUTRA origem (localhost ≠ 127.0.0.1) fala pela mesma ponte: é ignorado.
        let before = received.count
        let foreign = origin.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/v1/embed.html#host=native"
        _ = try await host.webView.evaluateJavaScript(
            "var f=document.createElement('iframe');f.src=\(BFocusJSON.quote(foreign));document.body.appendChild(f);1"
        )
        _ = try await waitForLog(base, "ready do iframe") { log in
            (log["sent"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "bfocus:ready" }.count >= 2
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(received.count, before, "mensagem de outra origem/subframe não pode passar")
    }

    @MainActor
    func testReleaseNotesBannerAndHistoryScripts() async throws {
        let base = try mockBase()
        let config = config(base)
        for (page, key, view) in [
            (BFocusPage.releaseNotesBanner(ids: ["a", "b"]), "release-notes:banner", "banner"),
            (BFocusPage.releaseNotesHistory, "release-notes:history", "history"),
        ] {
            let host = BFocusWebHost(allowedOrigin: try XCTUnwrap(config.embedOrigin))
            var received: [BFocusHostMessage] = []
            host.onMessage = { received.append($0) }
            let window = attach(host.webView)
            host.load(try XCTUnwrap(URL(string: BFocusEmbedURL.string(for: config, page: page) + "&script=all")))
            let expected = Scenarios.mockScript(key)
            try await waitUntil(key) { received.count >= expected.count }
            XCTAssertEqual(received.map(\.type), expected.map { $0["type"] as? String ?? "" }, key)
            XCTAssertEqual(received.first, .ready(hp: 1, widget: "release-notes", view: view), key)
            XCTAssertEqual(received.dropFirst().first, .releaseNotesBranding(primaryColor: "#123456"), key)
            window.isHidden = true
            host.tearDown()
        }
    }

    @MainActor
    func testCommandsWaitForReadyAndIdentityReloadRereadsFragment() async throws {
        let base = try mockBase()
        try await post(base, "__reset")
        var config = config(base)
        let host = BFocusWebHost(allowedOrigin: try XCTUnwrap(config.embedOrigin))
        var readies = 0
        host.onMessage = { if case .ready = $0 { readies += 1 } }
        let window = attach(host.webView)
        defer { window.isHidden = true; host.tearDown() }

        host.load(try XCTUnwrap(BFocusEmbedURL.url(for: config)))
        // Antes do ready: vai para a fila (só o último navigate vale) e sai depois.
        host.send(.navigate(BFocusNavigation(view: "list")))
        host.send(.navigate(BFocusNavigation(view: "new")))
        try await waitUntil("ready 1") { readies == 1 }
        let queued = try await waitForLog(base, "fila entregue") { ($0["received"] as? [Any])?.count ?? 0 >= 1 }
        XCTAssertEqual((queued["received"] as? [[String: Any]])?.first.map(NSDictionary.init(dictionary:)),
                       NSDictionary(dictionary: ["type": "bfocus:navigate", "payload": ["view": "new"]]))

        // userHash novo = só o fragmento muda: a página tem de recarregar (novo ready) com o user novo.
        config.userHash = "hash-novo"
        host.load(try XCTUnwrap(BFocusEmbedURL.url(for: config)))
        try await waitUntil("ready 2") { readies == 2 }
        let user = try await host.webView.evaluateJavaScript(
            "new URLSearchParams(location.hash.slice(1)).get('user')"
        ) as? String
        XCTAssertEqual(user, config.userBase64)
    }

    func testDownloaderSavesWithGivenName() async throws {
        let base = try mockBase()
        let file = try await BFocusDownloader.fetch(base.appendingPathComponent("files/manual.pdf"), filename: "../Manual Final.pdf")
        XCTAssertEqual(file.lastPathComponent, "Manual Final.pdf")
        let data = try Data(contentsOf: file)
        XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("%PDF"))
    }
}

/// Fachada `BFocus` sem apresentar telas (sem app hospedeiro não há janela).
final class FacadeTests: XCTestCase {
    @MainActor
    private func makeFacade(_ transport: FakeTransport, store: BFocusKeyValueStore = BFocusMemoryStore()) -> BFocus {
        let facade = BFocus()
        facade.transport = transport
        facade.store = store
        facade.presentingViewControllerProvider = { nil }
        facade.externalURLOpener = { _ in }
        return facade
    }

    private func config(key: String = "bf_pk_test_123", user: String = "USR-1") -> BFocusConfig {
        BFocusConfig(
            publishableKey: key,
            appId: "com.empresa.erp",
            user: BFocusUser(externalId: user),
            customer: BFocusCustomer(externalId: "ACME-1"),
            locale: .ptBR
        )
    }

    @MainActor
    func testInitializePublishesStateAndRejectsSecrets() async throws {
        let transport = FakeTransport { _ in FakeTransport.fixture("default") }
        let facade = makeFacade(transport)
        XCTAssertThrowsError(try facade.initialize(config: config(key: "bf_sk_segredo")))
        XCTAssertFalse(facade.isInitialized)

        var notes: [BFocusReleaseNotesState] = []
        facade.onReleaseNotesChanged = { notes.append($0) }
        try facade.initialize(config: config())
        await facade.engine?.waitForFirstCall()
        XCTAssertTrue(facade.isInitialized)
        XCTAssertEqual(facade.releaseNotes.label, "v4.2.0")
        XCTAssertEqual(facade.primaryColor, "#0EA5E9")
        XCTAssertEqual(notes.map(\.label), ["v4.2.0"])
        // Mesma configuração de novo: nada muda, nenhuma chamada extra.
        try facade.initialize(config: config())
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "X-bFocus-Client"), "ios/0.1.0")
        facade.logout()
    }

    @MainActor
    func testHandlePushOpensAtTheRightPlace() async throws {
        let transport = FakeTransport { _ in FakeTransport.fixture("default") }
        let facade = makeFacade(transport)
        XCTAssertFalse(facade.handlePush(["foo": "bar"]))
        // Antes do initialize: guarda e abre depois.
        XCTAssertTrue(facade.handlePush(["bfocus": "1", "type": "ticket.reply", "ticket_id": "t-1"]))
        XCTAssertNil(facade.ticketsController)
        try facade.initialize(config: config())
        XCTAssertEqual(facade.ticketsController?.initialTarget, .ticket("t-1"))
        XCTAssertTrue(facade.handlePush(["bfocus": "1", "type": "chat.message", "ticket_id": "t-2", "conversation_id": "c-1"]))
        XCTAssertEqual(facade.ticketsController?.initialTarget, .ticket("t-1"), "a WebView já existe: navega, não recria")
        facade.logout()
    }

    @MainActor
    func testPushTokenBeforeInitializeAndLogout() async throws {
        let transport = FakeTransport { request in
            request.url?.path == "/api/v1/widget/launcher-state" ? FakeTransport.fixture("default") : FakeTransport.ok(["ok": true])
        }
        let store = BFocusMemoryStore()
        let facade = makeFacade(transport, store: store)
        facade.registerPushToken("fcm-1")
        try facade.initialize(config: config())
        for _ in 0..<100 where transport.requests.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(transport.paths, ["/api/v1/widget/launcher-state", "/api/v1/widget/push/devices"])

        facade.logout()
        XCTAssertFalse(facade.isInitialized)
        XCTAssertEqual(facade.badgeLabel, "")
        for _ in 0..<100 where transport.requests.count < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(transport.paths.last, "/api/v1/widget/push/devices/unregister")
        XCTAssertNil(store.string(forKey: BFocusEngine.pushTokenKey))
    }
}
#endif
