#if canImport(UIKit) && os(iOS)
import Combine
import UIKit
import WebKit
import BFocusWidgetCore

/// Ponto de entrada do widget bFocus no iOS.
///
/// ```swift
/// try BFocus.shared.initialize(config: BFocusConfig(
///     publishableKey: "bf_pk_…",
///     user: BFocusUser(externalId: "USR-1", name: "Ana"),
///     customer: BFocusCustomer(externalId: "ACME-1"),
///     userHash: hashVindoDoSeuServidor))
/// BFocus.shared.open()
/// ```
///
/// Estado observável por Combine/SwiftUI (`@Published`) e também por closures (`onBadgeChanged`…).
@MainActor
public final class BFocus: ObservableObject {
    public static let shared = BFocus()

    // MARK: estado observável

    /// `''` | `'•'` | `'N'` | `'99+'`.
    @Published public private(set) var badgeLabel = ""
    /// Pílula de versão.
    @Published public private(set) var releaseNotes: BFocusReleaseNotesState = .placeholder
    /// Cor do tenant (`primary_color`); `nil` = identidade bFocus.
    @Published public private(set) var primaryColor: String?
    /// O widget de chamados está na tela.
    @Published public private(set) var isOpen = false
    @Published public private(set) var isInitialized = false

    /// Erros (`bfocus:error`, 401 de identidade).
    public var errors: AnyPublisher<BFocusError, Never> { errorSubject.eraseToAnyPublisher() }

    // MARK: callbacks

    public var onBadgeChanged: ((String) -> Void)?
    public var onReleaseNotesChanged: ((BFocusReleaseNotesState) -> Void)?
    public var onError: ((BFocusError) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?

    // MARK: personalização

    /// Como oferecer anexos baixados.
    public var downloadStyle: BFocusDownloadStyle = .share
    /// De onde apresentar o widget; padrão: o controller do topo da janela principal.
    public var presentingViewControllerProvider: (() -> UIViewController?)?
    /// Abre links externos; padrão: `UIApplication.shared.open`.
    public var externalURLOpener: ((URL) -> Void)?
    /// Transporte HTTP (troque antes do `initialize`; útil em testes).
    public var transport: BFocusHTTPTransport = BFocusURLSessionTransport()
    /// Onde gravar `last_seen` e o token de push (troque antes do `initialize`).
    public var store: BFocusKeyValueStore = BFocusUserDefaultsStore()

    public private(set) var config: BFocusResolvedConfig?
    public private(set) var engine: BFocusEngine?

    private let errorSubject = PassthroughSubject<BFocusError, Never>()
    var ticketsController: BFocusViewController?
    var historyController: BFocusViewController?
    var bannerController: BFocusViewController?
    private var pendingOpen: PendingOpen?
    private var pendingPresentation: BFocusViewController?
    private var observers: [NSObjectProtocol] = []

    private struct PendingOpen {
        let target: BFocusTarget?
    }

    public init() {
        observeApplication()
    }

    // MARK: API

    /// Valida a configuração e dispara a primeira consulta. Chamar de novo com a mesma
    /// configuração não faz nada; com outra identidade, recria as WebViews e registra de novo
    /// o token de push guardado.
    public func initialize(config: BFocusConfig) throws {
        let resolved = try config.resolved()
        if let current = self.config, current == resolved, engine != nil { return }
        endSession()
        self.config = resolved
        let engine = BFocusEngine(
            config: resolved,
            api: BFocusAPIClient(transport: transport),
            store: store,
            userHashProvider: config.userHashProvider
        )
        bind(engine)
        self.engine = engine
        badgeLabel = engine.badge.label
        releaseNotes = .placeholder
        primaryColor = nil
        isInitialized = true
        engine.start()
        if let token = engine.storedPushToken {
            let platform = store.string(forKey: BFocusEngine.pushPlatformKey) ?? BFocusPush.defaultPlatform
            Task { await engine.registerPush(token: token, platform: platform) }
        }
        if let pending = pendingOpen {
            pendingOpen = nil
            open(pending.target)
        }
    }

    /// Abre o widget. `nil` preserva a tela em que estava (na 1ª vez, a lista).
    public func open(_ target: BFocusTarget? = nil) {
        guard engine != nil, config != nil else {
            // Antes do initialize (ex.: toque num push com o app frio): abre depois.
            pendingOpen = PendingOpen(target: target)
            return
        }
        if let controller = ticketsController {
            // WebView já existe: navega (vai na fila até o bfocus:ready, se preciso).
            if let target { controller.host.send(.navigate(target.navigation)) }
            present(controller)
        } else if let controller = makeController(kind: .tickets, page: .tickets, target: target) {
            // Primeiro carregamento: o destino vai no `open=` da URL.
            ticketsController = controller
            present(controller)
        }
    }

    /// Fecha, mantendo a WebView para reabrir rápido.
    public func close() {
        if let controller = ticketsController { dismiss(controller) }
    }

    public func openReleaseNotesHistory() {
        guard engine != nil else { return }
        if historyController == nil {
            historyController = makeController(kind: .releaseNotesHistory, page: .releaseNotesHistory, target: nil)
        }
        if let controller = historyController { present(controller) }
    }

    /// Consulta o `launcher-state` agora.
    public func refresh() {
        guard let engine else { return }
        Task { await engine.refresh() }
    }

    /// Para a consulta, cancela o push, limpa o estado local e os dados da WebView do embed.
    public func logout() {
        guard let engine, let config else { return }
        let embedHost = URL(string: config.embedBase)?.host
        endSession()
        self.config = nil
        isInitialized = false
        badgeLabel = ""
        releaseNotes = .placeholder
        primaryColor = nil
        pendingOpen = nil
        Task {
            await engine.logout()
            await Self.clearWebsiteData(host: embedHost)
        }
    }

    /// Registra o token FCM do aparelho (espera a primeira consulta). Antes do `initialize`,
    /// guarda e registra quando a identidade existir.
    public func registerPushToken(_ token: String, platform: String = BFocusPush.defaultPlatform) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let engine else {
            store.setString(trimmed, forKey: BFocusEngine.pushTokenKey)
            store.setString(platform, forKey: BFocusEngine.pushPlatformKey)
            return
        }
        Task { await engine.registerPush(token: trimmed, platform: platform) }
    }

    /// `true` se a notificação é do bFocus; nesse caso abre o widget no item certo.
    @discardableResult
    public func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let navigation = BFocusPush.navigation(for: userInfo) else { return false }
        open(BFocusTarget(navigation: navigation))
        return true
    }

    /// Opcional: cria e carrega a WebView dos chamados antes do primeiro toque.
    public func prewarm() {
        guard engine != nil, ticketsController == nil,
              let controller = makeController(kind: .tickets, page: .tickets, target: nil) else { return }
        ticketsController = controller
        controller.loadViewIfNeeded()
    }

    // MARK: sessão

    private var controllers: [BFocusViewController] {
        [ticketsController, historyController, bannerController].compactMap { $0 }
    }

    private func bind(_ engine: BFocusEngine) {
        engine.delegate = self
        engine.onBadgeChanged = { [weak self] label in
            self?.badgeLabel = label
            self?.onBadgeChanged?(label)
        }
        engine.onReleaseNotesChanged = { [weak self] state in
            self?.releaseNotes = state
            self?.onReleaseNotesChanged?(state)
        }
        engine.onPrimaryColorChanged = { [weak self] color in
            guard let self else { return }
            self.primaryColor = color
            for controller in self.controllers { controller.brandColor = color }
        }
        engine.onError = { [weak self] error in
            self?.errorSubject.send(error)
            self?.onError?(error)
        }
    }

    /// Para a engine e descarta as telas/WebViews (logout ou identidade nova).
    private func endSession() {
        if let engine {
            engine.delegate = nil
            engine.onBadgeChanged = nil
            engine.onReleaseNotesChanged = nil
            engine.onPrimaryColorChanged = nil
            engine.onError = nil
            engine.stop()
        }
        engine = nil
        for controller in controllers {
            dismiss(controller)
            controller.host.tearDown()
        }
        ticketsController = nil
        historyController = nil
        bannerController = nil
        pendingPresentation = nil
        setOpen(false)
    }

    private func makeController(kind: BFocusViewController.Kind, page: BFocusPage, target: BFocusTarget?) -> BFocusViewController? {
        guard let config, let origin = config.embedOrigin else { return nil }
        let host = BFocusWebHost(allowedOrigin: origin, locale: config.locale)
        host.openExternal = { [weak self] url in self?.openURL(url) }
        let controller = BFocusViewController(
            kind: kind,
            host: host,
            page: page,
            initialTarget: target,
            locale: config.locale
        ) { [weak self] page, target in
            guard let self else { return nil }
            return await self.embedURL(page: page, target: target)
        }
        controller.brandColor = primaryColor
        host.onMessage = { [weak self, weak controller] message in
            guard let self, let controller else { return }
            self.route(message, from: controller)
        }
        host.onDownloadRequest = { [weak self, weak controller] url, filename in
            guard let self, let controller else { return }
            self.download(url, filename: filename, from: controller)
        }
        controller.onRequestClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.closeRequested(controller)
        }
        if kind == .tickets {
            controller.onAppear = { [weak self] in self?.setOpen(true) }
            controller.onDisappear = { [weak self] in self?.setOpen(false) }
        }
        return controller
    }

    private func embedURL(page: BFocusPage, target: BFocusTarget?) async -> URL? {
        guard let engine else { return nil }
        // Nada do embed antes da primeira chamada terminar (ela cria o usuário).
        await engine.waitForFirstCall()
        guard let config, engine === self.engine else { return nil }
        return BFocusEmbedURL.url(for: config, page: page, open: target)
    }

    private func route(_ message: BFocusHostMessage, from controller: BFocusViewController) {
        switch message {
        case .ready:
            break // o controller já tirou o "carregando"
        case .close:
            if controller.kind == .tickets { close() }
        case .unread, .seen, .branding, .releaseNotesBranding:
            engine?.handle(message)
        case .error(let error):
            engine?.handle(message)
            if error.code == BFocusError.userHashInvalid { renewIdentity(after: controller) }
        case .openExternal(let url):
            openURL(url)
        case .download(let url, let filename):
            download(url, filename: filename, from: controller)
        case .releaseNotesDone:
            guard controller.kind == .releaseNotesBanner else { return }
            dismiss(controller)
            controller.host.tearDown()
            if bannerController === controller { bannerController = nil }
            engine?.releaseBannerDidFinish()
        case .releaseNotesCloseHistory:
            if controller.kind == .releaseNotesHistory { dismiss(controller) }
        }
    }

    private func closeRequested(_ controller: BFocusViewController) {
        switch controller.kind {
        case .tickets:
            close()
        case .releaseNotesHistory:
            dismiss(controller)
        case .releaseNotesBanner:
            // Só aparece com a tela "sem conexão": sai sem confirmar; reabre numa próxima consulta.
            dismiss(controller)
            controller.host.tearDown()
            if bannerController === controller { bannerController = nil }
            engine?.releaseBannerDismissed()
        }
    }

    private func renewIdentity(after controller: BFocusViewController) {
        guard !controller.hashRetryUsed, let engine else { return }
        controller.hashRetryUsed = true
        // Se o hash mudar, o delegate recarrega as WebViews.
        Task { await engine.renewUserHash() }
    }

    private func setOpen(_ open: Bool) {
        guard isOpen != open else { return }
        isOpen = open
        engine?.setWidgetOpen(open)
        if open { onOpen?() } else { onClose?() }
    }

    private func download(_ url: URL, filename: String, from controller: BFocusViewController) {
        controller.setBusy(true)
        let style = downloadStyle
        Task { [weak controller] in
            do {
                let file = try await BFocusDownloader.fetch(url, filename: filename)
                guard let controller else { return }
                controller.setBusy(false)
                BFocusDownloader.present(file, style: style, from: controller)
            } catch {
                controller?.setBusy(false)
                controller?.showDownloadFailed()
            }
        }
    }

    private func openURL(_ url: URL) {
        if let opener = externalURLOpener {
            opener(url)
        } else {
            UIApplication.shared.open(url)
        }
    }

    // MARK: apresentação

    private func present(_ controller: BFocusViewController) {
        guard controller.presentingViewController == nil, !controller.isBeingPresented else { return }
        guard let presenter = topPresenter() else {
            // Sem janela ainda (app abrindo por um push): apresenta quando ficar ativo.
            pendingPresentation = controller
            return
        }
        presenter.present(controller, animated: true)
    }

    private func dismiss(_ controller: UIViewController) {
        if pendingPresentation === controller { pendingPresentation = nil }
        // Pelo apresentador: fecha também o que estiver por cima (folha de compartilhar…).
        controller.presentingViewController?.dismiss(animated: true)
    }

    private func topPresenter() -> UIViewController? {
        let root: UIViewController?
        if let provider = presentingViewControllerProvider {
            root = provider()
        } else {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.filter { $0.activationState == .foregroundActive }
            let windows = active.flatMap(\.windows) + scenes.flatMap(\.windows)
            root = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        }
        guard var top = root else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: ciclo do app

    private func observeApplication() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applicationDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applicationWillEnterForeground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applicationDidBecomeActive() }
            },
        ]
    }

    private func applicationDidEnterBackground() {
        // Consulta só em primeiro plano; o stream do chat desliga com o app em segundo plano.
        engine?.setForeground(false)
        if isOpen { ticketsController?.host.send(.close) }
    }

    private func applicationWillEnterForeground() {
        engine?.setForeground(true)
        if isOpen { ticketsController?.host.send(.open) }
    }

    private func applicationDidBecomeActive() {
        if let controller = pendingPresentation {
            pendingPresentation = nil
            present(controller)
        }
    }

    /// Apaga localStorage/cookies/cache só da origem do embed.
    private static func clearWebsiteData(host: String?) async {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return host == name || host.hasSuffix("." + name)
        }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: types, for: matching)
    }
}

extension BFocus: BFocusEngineDelegate {
    public func engine(_ engine: BFocusEngine, showReleaseBannerWith ids: [String]) {
        guard engine === self.engine else { return }
        if let controller = bannerController {
            // Outra fila com o banner aberto: recarrega com os ids novos.
            controller.page = .releaseNotesBanner(ids: ids)
            if controller.isViewLoaded { controller.loadPage() }
            present(controller)
            return
        }
        guard let controller = makeController(kind: .releaseNotesBanner, page: .releaseNotesBanner(ids: ids), target: nil) else {
            return
        }
        bannerController = controller
        present(controller)
    }

    public func engine(_ engine: BFocusEngine, didRenewIdentity config: BFocusResolvedConfig) {
        guard engine === self.engine else { return }
        self.config = config
        // Identidade nova (userHash): as WebViews recarregam com o `user=` novo.
        for controller in controllers where controller.isViewLoaded {
            controller.loadPage()
        }
    }
}
#endif
