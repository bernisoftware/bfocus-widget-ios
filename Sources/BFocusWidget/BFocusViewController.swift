#if canImport(UIKit) && os(iOS)
import Network
import UIKit
import BFocusWidgetCore

/// Tela cheia que hospeda o embed. A WebView (`host`) é mantida viva entre aberturas; mostra
/// "carregando" até o `bfocus:ready` e a tela própria de "sem conexão" se a página não carregar.
@MainActor
public final class BFocusViewController: UIViewController {
    public enum Kind: Equatable, Sendable {
        case tickets
        case releaseNotesHistory
        case releaseNotesBanner
    }

    public let kind: Kind
    public let host: BFocusWebHost
    public internal(set) var page: BFocusPage
    var initialTarget: BFocusTarget?
    /// O hash novo do `userHashProvider` é pedido UMA vez por tela (evita laço de recarga).
    var hashRetryUsed = false
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var brandColor: String? {
        didSet { if isViewLoaded { applyBrand() } }
    }

    private let strings: BFocusStrings
    private let urlBuilder: (BFocusPage, BFocusTarget?) async -> URL?
    private let loadingView = UIView()
    private let offlineView = UIView()
    private let busyView = UIView()
    private let retryButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var loadState: BFocusWebHost.LoadState = .loading
    private var loadTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?

    init(
        kind: Kind,
        host: BFocusWebHost,
        page: BFocusPage,
        initialTarget: BFocusTarget?,
        locale: BFocusLocale,
        urlBuilder: @escaping (BFocusPage, BFocusTarget?) async -> URL?
    ) {
        self.kind = kind
        self.host = host
        self.page = page
        self.initialTarget = initialTarget
        self.strings = BFocusStrings.forLocale(locale)
        self.urlBuilder = urlBuilder
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        // Banner de ciência: o usuário não fecha por gesto (tem de confirmar no embed).
        if kind == .releaseNotesBanner { isModalInPresentation = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        // O cabeçalho do embed tem a cor do tenant (escura): texto claro quando montado.
        loadState == .ready ? .lightContent : .default
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        let web = host.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        // Borda a borda (não na safe area): o embed pinta o notch com env(safe-area-*).
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildLoading()
        buildOffline()
        buildBusy()
        buildClose()
        applyBrand()
        host.dialogPresenter = self
        host.onLoadStateChange = { [weak self] state in self?.render(state) }
        if host.isReady {
            render(.ready)
        } else {
            loadPage()
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        host.send(.open)
        onAppear?()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Obrigatório ao esconder sem destruir: desliga o stream do chat.
        host.send(.close)
        onDisappear?()
    }

    /// (Re)carrega a URL atual da página (identidade nova, outra fila do banner, tentar de novo).
    func loadPage() {
        loadTask?.cancel()
        render(.loading)
        loadTask = Task { [weak self] in
            guard let self else { return }
            let url = await self.urlBuilder(self.page, self.initialTarget)
            guard !Task.isCancelled, let url else { return }
            self.host.load(url)
        }
    }

    func setBusy(_ busy: Bool) {
        guard isViewLoaded else { return }
        busyView.isHidden = !busy
        if busy { view.bringSubviewToFront(busyView) }
    }

    func showDownloadFailed() {
        guard isViewLoaded, view.window != nil else { return }
        let alert = UIAlertController(title: nil, message: strings.downloadFailed, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.ok, style: .default))
        present(alert, animated: true)
    }

    // MARK: estado

    private func render(_ state: BFocusWebHost.LoadState) {
        loadState = state
        guard isViewLoaded else { return }
        loadingView.isHidden = state != .loading
        offlineView.isHidden = state != .failed
        // Sem o embed na tela não há o ✕ dele; o banner só ganha ✕ quando falha.
        closeButton.isHidden = state == .ready || (kind == .releaseNotesBanner && state == .loading)
        view.bringSubviewToFront(closeButton)
        setNeedsStatusBarAppearanceUpdate()
        if state == .failed { startPathMonitor() } else { stopPathMonitor() }
    }

    /// Com a tela "sem conexão" aberta, tenta sozinho quando a rede volta.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        lastPathSatisfied = nil
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "br.com.bernisoftware.bfocus.network"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func pathChanged(_ satisfied: Bool) {
        // Só a transição sem rede → com rede (a 1ª leitura não conta, senão entraria em laço
        // quando a rede existe mas a CDN está fora).
        if satisfied, lastPathSatisfied == false, loadState == .failed { loadPage() }
        lastPathSatisfied = satisfied
    }

    private func applyBrand() {
        var config = UIButton.Configuration.filled()
        config.title = strings.retry
        config.baseBackgroundColor = BFocusColor.brand(brandColor)
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        retryButton.configuration = config
    }

    @objc private func retryTapped() {
        loadPage()
    }

    @objc private func closeTapped() {
        onRequestClose?()
    }

    // MARK: montagem

    private func pinFull(_ child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func centered(_ stack: UIStackView, in container: UIView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let guide = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -32),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
        ])
    }

    private func buildLoading() {
        loadingView.backgroundColor = .white
        pinFull(loadingView)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = BFocusColor.muted
        spinner.startAnimating()
        let label = UILabel()
        label.text = strings.loading
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = BFocusColor.muted
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        centered(stack, in: loadingView)
    }

    private func buildOffline() {
        offlineView.backgroundColor = .white
        offlineView.isHidden = true
        pinFull(offlineView)
        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.tintColor = BFocusColor.subtle
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        let title = UILabel()
        title.text = strings.offlineTitle
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = BFocusColor.text
        let message = UILabel()
        message.text = strings.offlineMessage
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.textColor = BFocusColor.muted
        message.numberOfLines = 0
        message.textAlignment = .center
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, title, message, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: message)
        centered(stack, in: offlineView)
    }

    private func buildBusy() {
        busyView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        busyView.isHidden = true
        pinFull(busyView)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        busyView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: busyView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: busyView.centerYAnchor),
        ])
    }

    private func buildClose() {
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = BFocusColor.muted
        closeButton.accessibilityLabel = strings.close
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
}
#endif
