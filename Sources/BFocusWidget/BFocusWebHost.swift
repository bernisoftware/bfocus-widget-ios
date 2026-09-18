#if canImport(UIKit) && os(iOS)
import UIKit
import WebKit
import BFocusWidgetCore

/// O `WKUserContentController` segura o handler com referência forte: o proxy fraco evita o
/// ciclo WebView → configuração → handler → WebView.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// WKWebView com a ponte do Host Protocol v1.
///
/// - Recebe por `webkit.messageHandlers.bfocus` e só aceita o FRAME PRINCIPAL da origem de
///   `embedBaseUrl` (`frameInfo.securityOrigin`).
/// - Manda com `window.bFocusEmbed && window.bFocusEmbed.receive(json)`; antes do `bfocus:ready`
///   os comandos ficam na fila (o embed ainda não montou a ponte).
/// - A navegação fica presa na origem do embed; o resto abre no navegador do sistema.
@MainActor
public final class BFocusWebHost: NSObject {
    public static let handlerName = "bfocus"

    public enum LoadState: Equatable, Sendable {
        case loading
        case ready
        case failed
    }

    public let webView: WKWebView
    public let allowedOrigin: BFocusOrigin
    public private(set) var isReady = false
    public private(set) var currentURL: URL?

    /// Mensagens aceitas e reconhecidas do embed.
    public var onMessage: ((BFocusHostMessage) -> Void)?
    public var onLoadStateChange: ((LoadState) -> Void)?
    /// Link para fora da origem do embed (navegação travada ou `target=_blank`).
    public var openExternal: (URL) -> Void = { url in UIApplication.shared.open(url) }
    /// `<a download>` ou resposta que a WebView não exibe: o pacote baixa.
    public var onDownloadRequest: ((URL, String) -> Void)?
    /// Onde mostrar `alert/confirm/prompt` do JS (o editor usa `prompt` para links).
    public weak var dialogPresenter: UIViewController?
    /// Sem `bfocus:ready` nesse tempo depois do carregamento = falha (mostra "sem conexão").
    public var readyTimeout: TimeInterval = 20

    private let strings: BFocusStrings
    private var pending: [BFocusHostCommand] = []
    private var readyTimer: Task<Void, Never>?

    public init(allowedOrigin: BFocusOrigin, locale: BFocusLocale = .ptBR) {
        self.allowedOrigin = allowedOrigin
        self.strings = BFocusStrings.forLocale(locale)
        let configuration = WKWebViewConfiguration()
        // Armazenamento persistente: o estado de "lido" dos chamados mora no localStorage.
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakScriptMessageHandler(self), name: Self.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        // O embed desenha a área segura com env(safe-area-*) (viewport-fit=cover).
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .white
    }

    /// Carrega (ou recarrega) a URL do embed.
    public func load(_ url: URL) {
        currentURL = url
        isReady = false
        readyTimer?.cancel()
        onLoadStateChange?(.loading)
        if let current = webView.url, Self.sameDocument(current, url) {
            // Só o fragmento muda (identidade nova, outra fila do banner): o WebKit trataria
            // como navegação na mesma página e o embed não releria os parâmetros.
            let script = "window.location.replace(\(BFocusJSON.quote(url.absoluteString))); window.location.reload(); 1"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in self?.webView.load(URLRequest(url: url)) }  // recaptura: Swift 5.10
            }
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func reload() {
        if let currentURL { load(currentURL) }
    }

    /// Manda um comando ao embed (guardado na fila até o `bfocus:ready`).
    public func send(_ command: BFocusHostCommand) {
        guard isReady else {
            enqueue(command)
            return
        }
        webView.evaluateJavaScript(command.script, completionHandler: nil)
    }

    /// Solta a ponte e para a página (logout, identidade nova).
    public func tearDown() {
        readyTimer?.cancel()
        pending.removeAll()
        onMessage = nil
        onLoadStateChange = nil
        onDownloadRequest = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    /// Mensagem vinda do frame principal da origem do embed?
    func accepts(isMainFrame: Bool, scheme: String, host: String, port: Int) -> Bool {
        isMainFrame && BFocusOrigin(scheme: scheme, host: host, port: port) == allowedOrigin
    }

    static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        guard var ca = URLComponents(url: a, resolvingAgainstBaseURL: false),
              var cb = URLComponents(url: b, resolvingAgainstBaseURL: false) else { return false }
        ca.fragment = nil
        cb.fragment = nil
        return ca.url == cb.url
    }

    private func enqueue(_ command: BFocusHostCommand) {
        // Só o último estado de visibilidade e a última navegação importam.
        switch command {
        case .open, .close:
            pending.removeAll { $0 == .open || $0 == .close }
        case .navigate:
            pending.removeAll { if case .navigate = $0 { return true } else { return false } }
        }
        pending.append(command)
    }

    private func markReady() {
        readyTimer?.cancel()
        let wasReady = isReady
        isReady = true
        if !wasReady { onLoadStateChange?(.ready) }
        let queued = pending
        pending.removeAll()
        for command in queued {
            webView.evaluateJavaScript(command.script, completionHandler: nil)
        }
    }

    private func loadFailed() {
        readyTimer?.cancel()
        guard !isReady else { return }
        onLoadStateChange?(.failed)
    }

    private func openOutside(_ url: URL) {
        guard BFocusHostMessage.externalSchemes.contains(url.scheme?.lowercased() ?? "") else { return }
        openExternal(url)
    }

    func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if #available(iOS 14.5, *), action.shouldPerformDownload {
            if scheme == "http" || scheme == "https" {
                onDownloadRequest?(url, BFocusFileName.sanitize(nil, fallback: url.lastPathComponent))
            }
            return .cancel
        }
        guard let frame = action.targetFrame else {
            // target=_blank / window.open: nunca abre dentro do widget.
            openOutside(url)
            return .cancel
        }
        if !frame.isMainFrame {
            // iframes do conteúdo (vídeo…) carregam; a ponte ignora mensagens deles.
            return ["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel
        }
        if scheme == "about" || allowedOrigin.matches(url) { return .allow }
        openOutside(url)
        return .cancel
    }
}

extension BFocusWebHost: WKScriptMessageHandler {
    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        let origin = message.frameInfo.securityOrigin
        guard accepts(
            isMainFrame: message.frameInfo.isMainFrame,
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port
        ), let parsed = BFocusHostMessage.parse(message.body) else { return }
        if case .ready = parsed { markReady() }
        onMessage?(parsed)
    }
}

extension BFocusWebHost: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(policy(for: navigationAction))
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            // CDN fora ou página ausente: a tela própria de "sem conexão", com nova tentativa.
            loadFailed()
            decisionHandler(.cancel)
            return
        }
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            let name = BFocusFileName.sanitize(navigationResponse.response.suggestedFilename, fallback: url.lastPathComponent)
            onDownloadRequest?(url, name)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReady else { return }
        readyTimer?.cancel()
        let nanos = UInt64(max(readyTimeout, 0) * 1_000_000_000)
        readyTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled, !self.isReady else { return }
            self.loadFailed()
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // O iOS matou o processo da página (memória): recarrega do zero.
        isReady = false
        if let currentURL { webView.load(URLRequest(url: currentURL)) }
    }

    private func handleFailure(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        // 102 = navegação interrompida pela nossa própria política (link externo, download).
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        loadFailed()
    }
}

extension BFocusWebHost: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openOutside(url) }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        guard let presenter = dialogPresenter, presenter.viewIfLoaded?.window != nil else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.ok, style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let presenter = dialogPresenter, presenter.viewIfLoaded?.window != nil else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.cancel, style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: strings.ok, style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let presenter = dialogPresenter, presenter.viewIfLoaded?.window != nil else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: strings.cancel, style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: strings.ok, style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
    }
}
#endif
