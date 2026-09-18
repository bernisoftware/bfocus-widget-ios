#if canImport(UIKit) && os(iOS)
import Combine
import UIKit
import BFocusWidgetCore

/// Botão flutuante de 56 pt com o balão e o badge, igual ao do widget web.
///
/// Por padrão segue o `BFocus.shared` (badge e cor do tenant) e abre o widget ao tocar. Com
/// `bindsToShared = false` vira só a peça visual: ligue `badgeText`/`color` e o toque você mesmo.
@MainActor
public final class BFocusLauncherButton: UIControl {
    public static let size: CGFloat = 56

    /// Tela aberta ao tocar (`nil` = a última).
    public var target: BFocusTarget?

    public var badgeText: String = "" {
        didSet { updateBadge() }
    }

    public var color: UIColor = BFocusColor.brand(nil) {
        didSet { backgroundColor = color }
    }

    public var bindsToShared = true {
        didSet { bind() }
    }

    private let iconLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    private let badge = UILabel()
    private var cancellables = Set<AnyCancellable>()

    public override init(frame: CGRect) {
        super.init(frame: frame.isEmpty ? CGRect(x: 0, y: 0, width: Self.size, height: Self.size) : frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: Self.size, height: Self.size)
    }

    public override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : 1 }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        // Ícone de 26 pt no centro (o SVG do web é 24×24 desenhado em 26 px).
        let iconRect = CGRect(x: (bounds.width - 26) / 2, y: (bounds.height - 26) / 2, width: 26, height: 26)
        iconLayer.frame = bounds
        dotsLayer.frame = bounds
        iconLayer.path = BFocusIcons.fit(BFocusIcons.balloon, in: iconRect)
        dotsLayer.path = BFocusIcons.fit(BFocusIcons.balloonDots, in: iconRect)
        layoutBadge()
    }

    private func setUp() {
        backgroundColor = color
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 6)

        iconLayer.fillColor = UIColor.clear.cgColor
        iconLayer.strokeColor = UIColor.white.cgColor
        iconLayer.lineWidth = 1.8 * 26 / 24
        iconLayer.lineCap = .round
        iconLayer.lineJoin = .round
        dotsLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(iconLayer)
        layer.addSublayer(dotsLayer)

        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.textAlignment = .center
        badge.backgroundColor = BFocusColor.badge
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = 2
        badge.layer.cornerRadius = 9
        badge.clipsToBounds = true
        badge.isUserInteractionEnabled = false
        badge.isHidden = true
        addSubview(badge)

        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        bind()
    }

    private func bind() {
        cancellables.removeAll()
        guard bindsToShared else { return }
        let shared = BFocus.shared
        accessibilityLabel = BFocusStrings.forLocale(shared.config?.locale ?? .device).launcher
        shared.$badgeLabel
            .sink { [weak self] label in self?.badgeText = label }
            .store(in: &cancellables)
        shared.$primaryColor
            .sink { [weak self] hex in self?.color = BFocusColor.brand(hex) }
            .store(in: &cancellables)
    }

    private func updateBadge() {
        badge.text = badgeText
        badge.isHidden = badgeText.isEmpty
        accessibilityValue = badgeText
        setNeedsLayout()
    }

    private func layoutBadge() {
        guard !badge.isHidden else { return }
        let textWidth = badge.intrinsicContentSize.width
        let width = max(18, textWidth + 10)
        // top/right -4 px, como no CSS do web.
        badge.frame = CGRect(x: bounds.maxX + 4 - width, y: -4, width: width, height: 18)
    }

    @objc private func tapped() {
        guard bindsToShared else { return }
        BFocus.shared.open(target)
    }
}
#endif
