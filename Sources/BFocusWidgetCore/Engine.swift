import Foundation

/// Quem mostra a UI (o módulo BFocusWidget) implementa isto.
@MainActor
public protocol BFocusEngineDelegate: AnyObject {
    /// O launcher-state trouxe `banner_ids` (e `autoShowReleaseBanner`): abrir ou trocar o banner.
    func engine(_ engine: BFocusEngine, showReleaseBannerWith ids: [String])
    /// O `userHash` mudou (userHashProvider): recarregar as WebViews com a identidade nova.
    func engine(_ engine: BFocusEngine, didRenewIdentity config: BFocusResolvedConfig)
}

/// Núcleo sem UI: launcher-state, badge, pílula, banner, push e erros de identidade.
///
/// Regras do BRIEF §4.1 que moram aqui:
/// - a primeira chamada sai no `start()` e nada mais do bFocus sai antes dela terminar;
/// - consulta a cada `pollIntervalSeconds` só em primeiro plano e com o widget fechado;
///   fechar o widget consulta na hora;
/// - rede/5xx em silêncio;
/// - 401 de identidade: com `userHashProvider`, pede um hash novo UMA vez e repete; `onError` só se
///   a repetição também for recusada. Sem provider, `onError` na hora;
/// - outros 4xx → `onError` com o código do envelope (ou `HTTP_<status>`);
/// - cada código é avisado uma vez por sequência de falhas (volta a avisar depois de um sucesso).
@MainActor
public final class BFocusEngine {
    public static let pushTokenKey = "bf:push:token"
    public static let pushPlatformKey = "bf:push:platform"

    public private(set) var config: BFocusResolvedConfig
    public let api: BFocusAPIClient
    public let store: BFocusKeyValueStore
    public let badge: BFocusBadgeModel

    public private(set) var releaseNotes: BFocusReleaseNotesState = .placeholder
    public private(set) var primaryColor: String?
    public private(set) var lastState: BFocusLauncherState?
    public private(set) var isForeground: Bool
    public private(set) var isWidgetOpen = false
    public private(set) var isStarted = false
    public private(set) var isStopped = false
    /// Fila do banner aberto agora (para não reabrir o mesmo conjunto).
    public private(set) var openBannerIds: [String]?

    public weak var delegate: BFocusEngineDelegate?
    public var onBadgeChanged: ((String) -> Void)?
    public var onReleaseNotesChanged: ((BFocusReleaseNotesState) -> Void)?
    public var onPrimaryColorChanged: ((String) -> Void)?
    public var onError: ((BFocusError) -> Void)?
    public var onLauncherState: ((BFocusLauncherState) -> Void)?

    private let userHashProvider: (@Sendable () async throws -> String)?
    private var firstCall: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var renewTask: Task<Bool, Never>?
    private var registeredPushToken: String?
    /// Número da consulta; resposta de consulta anterior ao `rn:done` não reabre o banner.
    private var fetchSeq = 0
    private var bannerMinSeq = 0
    /// Códigos de erro do launcher-state já avisados desde o último sucesso.
    private var reportedLauncherCodes: Set<String> = []

    public init(
        config: BFocusResolvedConfig,
        api: BFocusAPIClient = BFocusAPIClient(),
        store: BFocusKeyValueStore = BFocusUserDefaultsStore(),
        userHashProvider: (@Sendable () async throws -> String)? = nil,
        isForeground: Bool = true
    ) {
        self.config = config
        self.api = api
        self.store = store
        self.userHashProvider = userHashProvider
        self.isForeground = isForeground
        self.badge = BFocusBadgeModel(store: store, storageKey: config.lastSeenStorageKey)
        badge.onChange = { [weak self] label in self?.onBadgeChanged?(label) }
    }

    // MARK: ciclo de vida

    /// Dispara a primeira chamada (que cria o usuário no bFocus).
    public func start() {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        firstCall = beginFetch()
    }

    /// Espera a primeira chamada terminar (a WebView e o push esperam por ela).
    public func waitForFirstCall() async {
        await firstCall?.value
    }

    /// Consulta agora; junta-se a uma consulta em andamento em vez de disparar outra.
    public func refresh() async {
        guard isStarted, !isStopped else { return }
        await beginFetch().value
    }

    public func stop() {
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        inFlight?.cancel()
        inFlight = nil
        openBannerIds = nil
    }

    /// Para tudo, cancela o push e limpa o estado local desta identidade.
    public func logout() async {
        stop()
        _ = await unregisterPush()
        badge.reset()
        if releaseNotes != .placeholder {
            releaseNotes = .placeholder
            onReleaseNotesChanged?(releaseNotes)
        }
    }

    // MARK: visibilidade

    public func setWidgetOpen(_ open: Bool) {
        guard open != isWidgetOpen else { return }
        isWidgetOpen = open
        if open {
            badge.open()
            cancelPoll()
        } else {
            badge.close()
            // Fechar consulta na hora e volta ao intervalo.
            if isStarted, !isStopped { _ = beginFetch() }
        }
    }

    public func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        if foreground {
            if isStarted, !isStopped, !isWidgetOpen { _ = beginFetch() }
        } else {
            cancelPoll()
        }
    }

    // MARK: mensagens do embed

    public func handle(_ message: BFocusHostMessage) {
        switch message {
        case .unread(let count):
            badge.applyUnread(count)
        case .seen(let latest):
            badge.applySeen(latest)
        case .branding(let color), .releaseNotesBranding(let color):
            if let color { setPrimaryColor(color) }
        case .error(let error):
            report(error)
        default:
            break
        }
    }

    /// Banner terminou (`bfocus:rn:done`): libera o conjunto e consulta de novo.
    public func releaseBannerDidFinish() {
        openBannerIds = nil
        guard isStarted, !isStopped else { return }
        // Uma consulta já em voo pode trazer a fila de antes da ciência: ela não reabre o banner.
        bannerMinSeq = fetchSeq + 1
        if let running = inFlight {
            Task { [weak self] in
                await running.value
                _ = self?.beginFetch()
            }
        } else {
            _ = beginFetch()
        }
    }

    /// Banner fechado SEM terminar a fila (ex.: tela "sem conexão"): pode reabrir na próxima
    /// consulta, mas não força uma agora (evita reabrir em laço se a CDN estiver fora).
    public func releaseBannerDismissed() {
        openBannerIds = nil
    }

    /// `bfocus:error` de identidade vindo do embed: pede hash novo ao provider.
    /// `true` se o hash mudou (a UI recarrega a WebView).
    @discardableResult
    public func renewUserHash() async -> Bool {
        if let renewTask { return await renewTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performRenew()
        }
        renewTask = task
        let changed = await task.value
        renewTask = nil
        return changed
    }

    // MARK: push

    public var storedPushToken: String? { store.string(forKey: Self.pushTokenKey) }

    /// Registra o token FCM. Espera a primeira chamada; repetir o mesmo token não chama de novo.
    @discardableResult
    public func registerPush(token: String, platform: String = BFocusPush.defaultPlatform) async -> BFocusCallOutcome<Void> {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(status: nil, code: nil) }
        store.setString(token, forKey: Self.pushTokenKey)
        store.setString(platform, forKey: Self.pushPlatformKey)
        await waitForFirstCall()
        guard !isStopped else { return .failure(status: nil, code: nil) }
        if registeredPushToken == token { return .success(()) }
        let outcome = await api.registerPush(config, token: token, platform: platform)
        switch outcome {
        case .success:
            registeredPushToken = token
        case .identityError(let error):
            report(error)
        case .failure:
            break
        }
        return outcome
    }

    /// Cancela o registro do token guardado (logout). `nil` se não havia token.
    @discardableResult
    public func unregisterPush() async -> BFocusCallOutcome<Void>? {
        guard let token = storedPushToken else { return nil }
        store.setString(nil, forKey: Self.pushTokenKey)
        store.setString(nil, forKey: Self.pushPlatformKey)
        registeredPushToken = nil
        return await api.unregisterPush(config, token: token)
    }

    // MARK: interno

    private func beginFetch() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        guard !isStopped else { return Task {} }
        cancelPoll()
        fetchSeq += 1
        let seq = fetchSeq
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performFetch(seq: seq)
            self.fetchFinished()
        }
        inFlight = task
        return task
    }

    private func fetchFinished() {
        inFlight = nil
        schedulePoll()
    }

    private func cancelPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func schedulePoll() {
        cancelPoll()
        guard isStarted, !isStopped, isForeground, !isWidgetOpen, inFlight == nil else { return }
        let nanos = UInt64(max(config.pollIntervalSeconds, 0.01) * 1_000_000_000)
        pollTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            _ = self.beginFetch()
        }
    }

    private func performFetch(seq: Int) async {
        guard !isStopped else { return }
        var outcome = await api.launcherState(config)
        if case .identityError = outcome, !isStopped, await renewUserHash() {
            // Hash novo do provider: repete UMA vez; só avisa se a repetição também for recusada.
            outcome = await api.launcherState(config)
        }
        guard !isStopped else { return }
        switch outcome {
        case .success(let state):
            // Sucesso rearma o aviso: o mesmo erro volta a ser avisado se reaparecer.
            reportedLauncherCodes.removeAll()
            apply(state, seq: seq)
        case .identityError(let error):
            reportLauncherError(error)
        case .failure(let status, let code):
            // Rede e 5xx em silêncio; outros 4xx (origem, chave, widget desligado) avisam.
            if let status, (400..<500).contains(status) {
                reportLauncherError(BFocusError(code: code ?? "HTTP_\(status)"))
            }
        }
    }

    /// Erro do launcher-state: um aviso por código enquanto durar (a consulta repete a cada ciclo).
    private func reportLauncherError(_ error: BFocusError) {
        guard !reportedLauncherCodes.contains(error.code) else { return }
        reportedLauncherCodes.insert(error.code)
        report(error)
    }

    private func performRenew() async -> Bool {
        guard let provider = userHashProvider, !isStopped else { return false }
        let hash: String
        do {
            hash = try await provider().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            report(BFocusError(code: BFocusError.userHashProviderFailed, detail: String(describing: error)))
            return false
        }
        guard !isStopped, !hash.isEmpty, hash != config.userHash else { return false }
        config.userHash = hash
        delegate?.engine(self, didRenewIdentity: config)
        return true
    }

    private func apply(_ state: BFocusLauncherState, seq: Int) {
        lastState = state
        if let color = state.primaryColor, !color.isEmpty { setPrimaryColor(color) }
        badge.applyState(latestEventAt: state.tickets.latestEventAt)
        let notes = BFocusReleaseNotesState(payload: state.releaseNotes)
        if notes != releaseNotes {
            releaseNotes = notes
            onReleaseNotesChanged?(notes)
        }
        onLauncherState?(state)

        guard config.autoShowReleaseBanner, !notes.bannerIds.isEmpty, seq >= bannerMinSeq,
              openBannerIds != notes.bannerIds, let delegate else { return }
        openBannerIds = notes.bannerIds
        delegate.engine(self, showReleaseBannerWith: notes.bannerIds)
    }

    private func setPrimaryColor(_ color: String) {
        guard !color.isEmpty, color != primaryColor else { return }
        primaryColor = color
        onPrimaryColorChanged?(color)
    }

    private func report(_ error: BFocusError) {
        onError?(error)
    }
}
