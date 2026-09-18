import XCTest
import BFocusWidgetCore

/// Todos os casos aplicáveis de scenarios.json (BRIEF §5.1).
final class ConformanceTests: XCTestCase {
    func testScenarioFileMatchesProtocol() {
        XCTAssertEqual(Scenarios.root["hostProtocol"] as? Int, BFocusWidgetInfo.hostProtocol)
        XCTAssertEqual(Scenarios.defaults["apiBaseUrl"] as? String, BFocusResolvedConfig.defaultApiBase)
        XCTAssertEqual(Scenarios.defaults["embedBaseUrl"] as? String, BFocusResolvedConfig.defaultEmbedBase)
        XCTAssertEqual(Scenarios.defaults["pollIntervalSeconds"] as? Double, BFocusConfig.defaultPollIntervalSeconds)
    }

    func testUserPayloadJSONAndBase64() throws {
        let cases = Scenarios.list("userPayload")
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let configName = c["config"] as? String ?? ""
            for config in [Scenarios.config(configName), try Scenarios.publicConfig(configName)] {
                XCTAssertEqual(config.userJSON, c["json"] as? String, name)
                XCTAssertEqual(config.userBase64, c["base64"] as? String, name)
            }
        }
    }

    func testEmbedURL() throws {
        let cases = Scenarios.list("embedUrl")
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let configName = c["config"] as? String ?? ""
            let page = Self.page(c)
            let mode = BFocusHostMode(rawValue: c["mode"] as? String ?? "") ?? .native
            let target = (c["open"] as? String).map(Self.target(open:))
            let expect = c["expect"] as? String
            for config in [Scenarios.config(configName), try Scenarios.publicConfig(configName)] {
                XCTAssertEqual(BFocusEmbedURL.string(for: config, page: page, mode: mode, open: target), expect, name)
                // O URL do Foundation não reescreve nada da string.
                XCTAssertEqual(BFocusEmbedURL.url(for: config, page: page, mode: mode, open: target)?.absoluteString, expect, name)
            }
        }
    }

    func testLauncherStateRequest() throws {
        let cases = Scenarios.list("launcherStateRequest")
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let configName = c["config"] as? String ?? ""
            let expect = c["expect"] as? [String: Any] ?? [:]
            for config in [Scenarios.config(configName), try Scenarios.publicConfig(configName)] {
                let request = BFocusRequests.launcherState(config)
                XCTAssertEqual(request.httpMethod, expect["method"] as? String, name)
                XCTAssertEqual(request.url?.absoluteString, expect["url"] as? String, name)
                XCTAssertEqual(request.allHTTPHeaderFields, expect["headers"] as? [String: String], name)
                XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, expect["body"] as? String, name)
                XCTAssertEqual(request.timeoutInterval, 15, name)
            }
        }
    }

    func testBadgeSteps() {
        let cases = Scenarios.list("badge")
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let initial = c["initial"] as? [String: Any] ?? [:]
            let store = BFocusMemoryStore()
            let key = BFocusBadgeModel.storageKey(publishableKey: "bf_pk_x", userExternalId: "U", customerExternalId: "C")
            if let lastSeen = initial["last_seen"] as? String { store.setString(lastSeen, forKey: key) }
            let model = BFocusBadgeModel(store: store, storageKey: key, label: initial["label"] as? String ?? "")
            for (index, step) in (c["steps"] as? [[String: Any]] ?? []).enumerated() {
                let where_ = "\(name), passo \(index)"
                switch step["op"] as? String {
                case "state": model.applyState(latestEventAt: step["latest_event_at"] as? String)
                case "unread": model.applyUnread(step["count"] as? Int ?? 0)
                case "seen": model.applySeen(step["latest_event_at"] as? String)
                case "open": model.open()
                case "close": model.close()
                default: XCTFail("op desconhecida em \(where_)")
                }
                let expect = step["expect"] as? [String: Any] ?? [:]
                if let label = expect["label"] as? String { XCTAssertEqual(model.label, label, where_) }
                if expect.keys.contains("last_seen") {
                    XCTAssertEqual(model.lastSeen, expect["last_seen"] as? String, where_)
                }
            }
        }
    }

    func testPill() throws {
        let cases = Scenarios.list("pill")
        XCTAssertEqual(cases.count, 4)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let payload = try JSONDecoder().decode(BFocusReleaseNotesPayload.self, from: Scenarios.json(c["releaseNotes"] ?? [:]))
            let state = BFocusReleaseNotesState(payload: payload)
            let expect = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(state.label, expect["label"] as? String, name)
            XCTAssertEqual(state.dot, expect["dot"] as? Bool, name)
            XCTAssertEqual(state.bannerIds, expect["bannerIds"] as? [String], name)
        }
    }

    func testPushRegister() throws {
        let c = Scenarios.push["register"] as? [String: Any] ?? [:]
        let config = Scenarios.config(c["config"] as? String ?? "")
        let request = BFocusRequests.pushRegister(config, token: c["token"] as? String ?? "", platform: c["platform"] as? String ?? "")
        try assertRequest(request, matches: c["expect"] as? [String: Any] ?? [:], config: config)
    }

    func testPushUnregister() throws {
        let c = Scenarios.push["unregister"] as? [String: Any] ?? [:]
        let config = Scenarios.config(c["config"] as? String ?? "")
        let request = BFocusRequests.pushUnregister(config, token: c["token"] as? String ?? "")
        try assertRequest(request, matches: c["expect"] as? [String: Any] ?? [:], config: config)
    }

    func testPushHandle() throws {
        let cases = Scenarios.push["handle"] as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let data = c["data"] as? [String: Any] ?? [:]
            let navigation = BFocusPush.navigation(for: data)
            let expect = c["expect"] as? [String: Any] ?? [:]
            XCTAssertEqual(navigation != nil, expect["handled"] as? Bool, name)
            if let expected = expect["navigate"] as? [String: Any] {
                XCTAssertEqual(navigation.map { NSDictionary(dictionary: $0.jsonObject) }, NSDictionary(dictionary: expected), name)
                // O que vai ao embed (bfocus:navigate) é o mesmo objeto, e o destino faz o caminho de volta.
                let command = BFocusHostCommand.navigate(navigation!).json
                let sent = try JSONSerialization.jsonObject(with: Data(command.utf8)) as? [String: Any]
                XCTAssertEqual(sent?["type"] as? String, "bfocus:navigate", name)
                XCTAssertEqual((sent?["payload"] as? [String: Any]).map(NSDictionary.init(dictionary:)), NSDictionary(dictionary: expected), name)
                XCTAssertEqual(BFocusTarget(navigation: navigation!).navigation, navigation, name)
            } else {
                XCTAssertNil(navigation, name)
            }
        }
    }

    // MARK: apoio

    private func assertRequest(_ request: URLRequest, matches expect: [String: Any], config: BFocusResolvedConfig) throws {
        XCTAssertEqual(request.httpMethod, expect["method"] as? String)
        XCTAssertEqual(request.url?.absoluteString, expect["url"] as? String)
        // Mesmos headers do launcher-state.
        XCTAssertEqual(request.allHTTPHeaderFields, BFocusRequests.headers(config))
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body.map(NSDictionary.init(dictionary:)), (expect["json"] as? [String: Any]).map(NSDictionary.init(dictionary:)))
    }

    static func page(_ c: [String: Any]) -> BFocusPage {
        if c["page"] as? String == "embed" { return .tickets }
        if c["view"] as? String == "banner" { return .releaseNotesBanner(ids: c["ids"] as? [String] ?? []) }
        return .releaseNotesHistory
    }

    static func target(open: String) -> BFocusTarget {
        if open.hasPrefix("ticket:") { return .ticket(String(open.dropFirst("ticket:".count))) }
        switch open {
        case "new": return .new
        case "chat": return .chat
        default: return .list
        }
    }
}
