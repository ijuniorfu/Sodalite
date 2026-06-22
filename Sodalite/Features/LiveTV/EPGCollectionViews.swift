import UIKit

/// Solid backing for the channel column / time header / corner. Opaque so the
/// hard-split program grid beside them reads as a separate panel.
let epgPinnedBackground = UIColor(white: 0.12, alpha: 1.0)

// MARK: - Program cell (focusable)

/// One program block. Focusable; fills tinted (not white) while focused, per the app convention.
final class EPGProgramCollectionCell: UICollectionViewCell {
    static let reuseID = "EPGProgramCollectionCell"

    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let container = UIView()
    private let recordDot = UIView()
    private var tint: UIColor = .systemBlue
    private var isOnNow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = 10
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        timeLabel.font = .preferredFont(forTextStyle: .caption1)
        timeLabel.textColor = .secondaryLabel

        recordDot.backgroundColor = .systemRed
        recordDot.layer.cornerRadius = 5
        recordDot.translatesAutoresizingMaskIntoConstraints = false
        recordDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        recordDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        recordDot.isHidden = true
        // Keep the outer stack from stretching the dot vertically.
        recordDot.setContentHuggingPriority(.required, for: .vertical)
        recordDot.setContentCompressionResistancePriority(.required, for: .vertical)

        let titleRow = UIStackView(arrangedSubviews: [recordDot, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [titleRow, timeLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // A very short program is a cell a few points wide where the horizontal insets (container
        // 2+2, stack 12+12) can't fit. Drop them just below required so they yield silently (no
        // "unable to satisfy constraints" spam; container clips the label). Vertical insets stay
        // required (fixed row height always fits).
        let containerLeading = container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2)
        let containerTrailing = container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2)
        let stackLeading = stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)
        let stackTrailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12)
        [containerLeading, containerTrailing, stackLeading, stackTrailing].forEach {
            $0.priority = UILayoutPriority(999)
        }
        NSLayoutConstraint.activate([
            containerLeading,
            containerTrailing,
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stackLeading,
            stackTrailing,
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        applyFocusStyle(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String?, tint: UIColor, isOnNow: Bool, hasTimer: Bool = false) {
        self.tint = tint
        self.isOnNow = isOnNow
        titleLabel.text = title
        timeLabel.text = subtitle
        timeLabel.isHidden = (subtitle == nil)
        recordDot.isHidden = !hasTimer
        applyFocusStyle(focused: isFocused)
    }

    /// Update only the record-timer dot, without re-running configure.
    func setTimer(_ hasTimer: Bool) {
        recordDot.isHidden = !hasTimer
    }

    /// Update only the "currently airing" state (now-line timer driven), without re-running configure.
    func setOnNow(_ value: Bool) {
        guard value != isOnNow else { return }
        isOnNow = value
        applyFocusStyle(focused: isFocused)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations { [weak self] in
            self?.applyFocusStyle(focused: focused)
        }
    }

    private func applyFocusStyle(focused: Bool) {
        container.backgroundColor = focused ? tint : UIColor.white.withAlphaComponent(0.08)
        titleLabel.textColor = .white
        // An airing program keeps a tinted outline even unfocused so the live row reads at a glance.
        if isOnNow {
            container.layer.borderColor = tint.cgColor
            container.layer.borderWidth = 2
        } else {
            container.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
            container.layer.borderWidth = 1
        }
    }
}

// MARK: - Channel column cell (not focusable)

final class EPGChannelCell: UICollectionViewCell {
    static let reuseID = "EPGChannelCell"

    private let logoView = UIImageView()
    private let nameLabel = UILabel()
    private let numberLabel = UILabel()
    private let favoriteIcon = UIImageView()
    private var logoToken = UUID()

    // The column is a passive index; focus lives on the program grid.
    override var canBecomeFocused: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = epgPinnedBackground
        logoView.contentMode = .scaleAspectFit
        logoView.tintColor = .secondaryLabel
        logoView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        numberLabel.font = .preferredFont(forTextStyle: .caption1)
        numberLabel.textColor = .secondaryLabel

        let textStack = UIStackView(arrangedSubviews: [nameLabel, numberLabel])
        textStack.axis = .vertical
        textStack.spacing = 2

        let hStack = UIStackView(arrangedSubviews: [logoView, textStack])
        hStack.axis = .horizontal
        hStack.spacing = 12
        hStack.alignment = .center
        hStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hStack)

        favoriteIcon.image = UIImage(systemName: "star.fill")
        favoriteIcon.tintColor = .systemYellow
        favoriteIcon.contentMode = .scaleAspectFit
        favoriteIcon.isHidden = true
        favoriteIcon.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(favoriteIcon)

        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 56),
            logoView.heightAnchor.constraint(equalToConstant: 56),
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(lessThanOrEqualTo: favoriteIcon.leadingAnchor, constant: -8),
            hStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            favoriteIcon.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            favoriteIcon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            favoriteIcon.widthAnchor.constraint(equalToConstant: 28),
            favoriteIcon.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, number: String?, logoURL: URL?, isFavorite: Bool) {
        nameLabel.text = name
        numberLabel.text = number
        numberLabel.isHidden = (number == nil)
        favoriteIcon.isHidden = !isFavorite
        loadLogo(logoURL)
    }

    /// Update only the favorite star (optimistic toggle), without re-running configure / reloading the logo.
    func setFavorite(_ value: Bool) {
        favoriteIcon.isHidden = !value
    }

    /// Shared decoded-logo cache: cell reuse on a long channel list used to re-fetch + re-decode
    /// each logo from URLSession.shared every scroll pass (elsewhere images use AsyncCachedImage).
    private static let logoCache = NSCache<NSURL, UIImage>()

    private func loadLogo(_ url: URL?) {
        let token = UUID()
        logoToken = token
        logoView.image = UIImage(systemName: "tv")
        guard let url else { return }
        if let cached = Self.logoCache.object(forKey: url as NSURL) {
            logoView.image = cached
            return
        }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                Self.logoCache.setObject(image, forKey: url as NSURL)
                guard let self, self.logoToken == token else { return }
                self.logoView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoToken = UUID()
        logoView.image = UIImage(systemName: "tv")
        favoriteIcon.isHidden = true
    }
}

// MARK: - Time header content (placed inside a sync scroll view)

/// Tick labels across the timeline, hosted in a non-focusable scroll container synced to the grid.
final class EPGTimeHeaderContentView: UIView {
    private var tickLabels: [UILabel] = []
    private var ticks: [(x: CGFloat, text: String)] = []

    func configure(ticks: [(x: CGFloat, text: String)]) {
        self.ticks = ticks
        tickLabels.forEach { $0.removeFromSuperview() }
        tickLabels = ticks.map { tick in
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = .secondaryLabel
            label.text = tick.text
            addSubview(label)
            return label
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, label) in tickLabels.enumerated() {
            label.sizeToFit()
            label.frame.origin = CGPoint(x: ticks[i].x + 6, y: (bounds.height - label.bounds.height) / 2)
        }
    }
}

// MARK: - Now line (decoration)

final class EPGNowLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemRed
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Time gridline (decoration)

/// Half-hour vertical tick line, drawn behind the cells (layout zIndex -1).
final class EPGGridLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
