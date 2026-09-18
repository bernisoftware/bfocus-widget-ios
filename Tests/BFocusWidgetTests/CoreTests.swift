import XCTest
import BFocusWidgetCore

/// Casos de borda do núcleo que o scenarios.json não cobre.
final class CoreTests: XCTestCase {
    func testClientHeaderIsIOS() {
        XCTAssertEqual(BFocusWidgetInfo.client, "ios/0.1.0")
    }

    func testRFC3986Encoding() {
        XCTAssertEqual(BFocusURLEncoding.component("a b"), "a%20b")
        XCTAssertEqual(BFocusURLEncoding.component("!'()*"), "%21%27%28%29%2A")
        XCTAssertEqual(BFocusURLEncoding.component("ç/+:="), "%C3%A7%2F%2B%3A%3D")
        XCTAssertEqual(BFocusURLEncoding.component("Az09-._~"), "Az09-._~")
    }

    func testUserJSONEscapesLikeJavaScript() {
        let json = BFocusUserPayload.json(
            user: BFocusUser(externalId: "U\"1\\\n\u{01}", name: ""),
            customer: BFocusCustomer(externalId: "C", website: "https://a.b/c"),
            userHash: nil,
            locale: .es
        )
        // Sem escapar "/" (JSONSerialization escaparia), vazio some, controles como \u00xx.
        XCTAssertEqual(json, #"{"externalId":"U\"1\\\n"# + "\\" + "u0001" + #"","locale":"es","customer":{"externalId":"C","website":"https://a.b/c"}}"#)
    }

    func testInstantParsing() throws {
        let base = try XCTUnwrap(BFocusInstant.parse("2026-09-01T10:00:00+00:00"))
        XCTAssertEqual(BFocusInstant.parse("2026-09-01T07:00:00-03:00"), base)
        XCTAssertEqual(BFocusInstant.parse("2026-09-01T10:00:00Z"), base)
        XCTAssertEqual(BFocusInstant.parse("2026-09-01T10:00:00"), base)
        XCTAssertEqual(BFocusInstant.parse("2026-09-01T10:00:00+0000"), base)
        let micro = try XCTUnwrap(BFocusInstant.parse("2026-09-01T10:00:00.123456+00:00"))
        XCTAssertEqual(micro.timeIntervalSince(base), 0.123456, accuracy: 0.000_01)
        XCTAssertNil(BFocusInstant.parse("ontem"))
        XCTAssertNil(BFocusInstant.parse("2026-13-01T10:00:00Z"))
        XCTAssertTrue(BFocusInstant.isAfter("2026-09-01T10:00:00.5+00:00", "2026-09-01T07:00:00-03:00"))
        XCTAssertFalse(BFocusInstant.isAfter("2026-09-01T07:00:00-03:00", "2026-09-01T10:00:00+00:00"))
    }

    func testHostMessagesFromMockScripts() {
        for name in ["tickets", "release-notes:banner", "release-notes:history"] {
            let script = Scenarios.mockScript(name)
            XCTAssertFalse(script.isEmpty, name)
            for raw in script {
                let json = String(decoding: Scenarios.json(raw), as: UTF8.self)
                    .replacingOccurrences(of: "{origin}", with: "http://127.0.0.1:8787")
                let message = BFocusHostMessage.parse(json)
                XCTAssertEqual(message?.type, raw["type"] as? String, "\(name): \(json)")
            }
        }
        XCTAssertEqual(
            BFocusHostMessage.parse(#"{"type":"bfocus:download","payload":{"url":"http://127.0.0.1:8787/files/manual.pdf","filename":"manual.pdf"}}"#),
            .download(url: URL(string: "http://127.0.0.1:8787/files/manual.pdf")!, filename: "manual.pdf")
        )
        XCTAssertEqual(BFocusHostMessage.parse(#"{"type":"bfocus:unread","payload":{"count":120}}"#), .unread(count: 120))
        XCTAssertEqual(BFocusHostMessage.parse(["type": "bfocus:close"]), .close)
    }

    func testHostMessagesRejectUnknownAndUnsafe() {
        XCTAssertNil(BFocusHostMessage.parse(#"{"type":"bfocus:algo-novo"}"#))
        XCTAssertNil(BFocusHostMessage.parse(#"{"type":"outra:coisa"}"#))
        XCTAssertNil(BFocusHostMessage.parse("não é json"))
        XCTAssertNil(BFocusHostMessage.parse(42))
        XCTAssertNil(BFocusHostMessage.parse(#"{"type":"bfocus:openExternal","payload":{"url":"javascript:alert(1)"}}"#))
        XCTAssertNil(BFocusHostMessage.parse(#"{"type":"bfocus:download","payload":{"url":"file:///etc/passwd"}}"#))
        XCTAssertEqual(
            BFocusHostMessage.parse(#"{"type":"bfocus:download","payload":{"url":"https://x.y/a.pdf","filename":"../../etc/passwd"}}"#),
            .download(url: URL(string: "https://x.y/a.pdf")!, filename: "passwd")
        )
    }

    func testCommandsScript() {
        XCTAssertEqual(BFocusHostCommand.open.script, #"window.bFocusEmbed && window.bFocusEmbed.receive({"type":"bfocus:open"})"#)
        XCTAssertEqual(BFocusHostCommand.close.json, #"{"type":"bfocus:close"}"#)
        XCTAssertEqual(
            BFocusHostCommand.navigate(BFocusNavigation(view: "ticket", ticketId: "t-\"1")).json,
            #"{"type":"bfocus:navigate","payload":{"view":"ticket","ticketId":"t-\"1"}}"#
        )
    }

    func testOrigin() throws {
        let embed = try XCTUnwrap(BFocusOrigin(url: URL(string: "https://widget.bfocus.com.br/v1")!))
        XCTAssertEqual(embed, BFocusOrigin(scheme: "https", host: "WIDGET.bfocus.com.br", port: 0))
        XCTAssertEqual(embed, BFocusOrigin(scheme: "https", host: "widget.bfocus.com.br", port: 443))
        XCTAssertTrue(embed.matches(URL(string: "https://widget.bfocus.com.br/v1/embed.html#x=1")!))
        XCTAssertFalse(embed.matches(URL(string: "https://evil.com/v1/embed.html")!))
        XCTAssertFalse(embed.matches(URL(string: "http://widget.bfocus.com.br/v1/embed.html")!))
        let local = try XCTUnwrap(BFocusOrigin(url: URL(string: "http://127.0.0.1:8787/v1")!))
        XCTAssertFalse(local.matches(URL(string: "http://127.0.0.1:8788/v1/embed.html")!))
        XCTAssertEqual(local.description, "http://127.0.0.1:8787")
    }

    func testConfigValidation() throws {
        func make(_ key: String = "bf_pk_live_1", appId: String? = "com.x", api: String = "https://api.bfocus.com.br") -> BFocusConfig {
            BFocusConfig(
                publishableKey: key,
                appId: appId,
                user: BFocusUser(externalId: "U"),
                customer: BFocusCustomer(externalId: "C"),
                apiBaseUrl: URL(string: api)!
            )
        }
        for secret in ["bf_whs_abc", "bf_live_abc", "bf_sk_abc"] {
            XCTAssertThrowsError(try make(secret).resolved()) { XCTAssertEqual($0 as? BFocusConfigError, .secretKeyInApp) }
        }
        XCTAssertThrowsError(try make("chave").resolved()) { XCTAssertEqual($0 as? BFocusConfigError, .invalidPublishableKey) }
        XCTAssertThrowsError(try make(appId: nil).resolved(defaultAppId: nil)) { XCTAssertEqual($0 as? BFocusConfigError, .missingAppId) }
        XCTAssertThrowsError(try make(api: "http://api.bfocus.com.br").resolved()) {
            XCTAssertEqual($0 as? BFocusConfigError, .insecureURL("http://api.bfocus.com.br"))
        }
        XCTAssertNoThrow(try make(api: "http://127.0.0.1:8787").resolved())
        XCTAssertNoThrow(try make(api: "http://localhost:8787").resolved())

        let resolved = try make(appId: nil).resolved(defaultAppId: "Com.Bundle.App", deviceLocale: .es)
        XCTAssertEqual(resolved.parentOrigin, "app://com.bundle.app")
        XCTAssertEqual(resolved.locale, .es)
        XCTAssertEqual(resolved.client, "ios/0.1.0")
        XCTAssertNil(resolved.userHash)
    }

    func testLocaleMapping() {
        XCTAssertEqual(BFocusLocale(languageTag: "pt-PT"), .ptBR)
        XCTAssertEqual(BFocusLocale(languageTag: "pt_BR"), .ptBR)
        XCTAssertEqual(BFocusLocale(languageTag: "es-MX"), .es)
        XCTAssertEqual(BFocusLocale(languageTag: "fr-FR"), .en)
        XCTAssertEqual(BFocusLocale(languageTag: "en"), .en)
    }

    func testLauncherStateDecodingIsTolerant() throws {
        let empty = try BFocusLauncherState.decodeEnvelope(Data(#"{"code":"OK","data":{},"message":""}"#.utf8))
        XCTAssertEqual(empty, BFocusLauncherState())
        let full = try BFocusLauncherState.decodeEnvelope(Scenarios.json(["code": "OK", "data": Scenarios.fixture("banner"), "message": ""]))
        XCTAssertEqual(full.primaryColor, "#0EA5E9")
        XCTAssertNil(full.tickets.latestEventAt)
        XCTAssertEqual(full.releaseNotes.bannerIds.count, 2)
        XCTAssertThrowsError(try BFocusLauncherState.decodeEnvelope(Data(#"{"code":"OK","data":null}"#.utf8)))
    }

    func testEnvelopeErrors() async {
        let config = Scenarios.config("min")
        func outcome(_ status: Int, _ body: String) async -> BFocusCallOutcome<BFocusLauncherState> {
            let transport = FakeTransport { _ in BFocusHTTPResponse(statusCode: status, body: Data(body.utf8)) }
            return await BFocusAPIClient(transport: transport).launcherState(config)
        }
        if case .identityError(let error) = await outcome(401, #"{"code":"ERROR","data":null,"message":"WIDGET_USER_HASH_INVALID"}"#) {
            XCTAssertEqual(error.code, BFocusError.userHashInvalid)
        } else { XCTFail("401 message") }
        if case .identityError(let error) = await outcome(401, #"{"detail":"WIDGET_VERIFIED_SESSION_REQUIRED"}"#) {
            XCTAssertEqual(error.code, BFocusError.verifiedSessionRequired)
        } else { XCTFail("401 detail") }
        if case .failure(let status, let code) = await outcome(403, #"{"message":"WIDGET_ORIGIN_NOT_ALLOWED"}"#) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(code, "WIDGET_ORIGIN_NOT_ALLOWED")
        } else { XCTFail("403") }
        if case .failure(let status, _) = await outcome(502, "<html>") {
            XCTAssertEqual(status, 502)
        } else { XCTFail("502") }
        if case .failure(let status, _) = await outcome(200, "{") {
            XCTAssertEqual(status, 200)
        } else { XCTFail("json inválido") }
    }

    func testFileNameSanitize() {
        XCTAssertEqual(BFocusFileName.sanitize("relatório final.pdf"), "relatório final.pdf")
        XCTAssertEqual(BFocusFileName.sanitize("a/b\\c:d.txt"), "c_d.txt")
        XCTAssertEqual(BFocusFileName.sanitize("..", fallback: "x.pdf"), "x.pdf")
        XCTAssertEqual(BFocusFileName.sanitize(nil, fallback: ""), "download")
    }

    func testPushVariants() {
        XCTAssertEqual(BFocusPush.navigation(for: ["bfocus": 1, "type": "ticket.reply", "ticket_id": "t"]), BFocusNavigation(view: "ticket", ticketId: "t"))
        XCTAssertEqual(
            BFocusPush.navigation(for: ["bfocus": #"{"type":"chat.message","conversation_id":"c"}"#]),
            BFocusNavigation(view: "chat", conversationId: "c")
        )
        XCTAssertEqual(BFocusPush.navigation(for: ["bfocus": "1", "type": "ticket.reply"]), BFocusNavigation(view: "list"))
        XCTAssertNil(BFocusPush.navigation(for: ["bfocus": "0", "type": "ticket.reply"]))
        XCTAssertNil(BFocusPush.navigation(for: [:]))
    }
}
