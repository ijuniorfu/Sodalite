import UIKit

/// Solid backing for the channel column / time header / corner. Opaque so the
/// hard-split program grid beside them reads as a separate panel.
let epgPinnedBackground = UIColor(white: 0.12, alpha: 1.0)

// MARK: - Program cell (focusable)

/// One program block in the program grid. Focusable; fills with the tint while
/// focused (matching the SwiftUI convention of tinted-not-white focus).
final class EPGProgramCollectionCell: UICollectionViewCell {
    static let reuseID = "EPGProgramCollectionCell"

    private let titleLabel = UILabel()
    private let timeLabel = UILabel()
    private let container = UIView()
    private var tint: UIColor = .systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = 10
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        timeLabel.font = .preferredFont(forTextStyle: .caption1)
        timeLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleLabel, timeLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        applyFocusStyle(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String?, tint: UIColor) {
        self.tint = tint
        titleLabel.text = title
        timeLabel.text = subtitle
        timeLabel.isHidden = (subtitle == nil)
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
    }
}

// MARK: - Channel column cell (not focusable)

final class EPGChannelCell: UICollectionViewCell {
    static let reuseID = "EPGChannelCell"

    private let logoView = UIImageView()
    private let nameLabel = UILabel()
    private let numberLabel = UILabel()
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

        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 56),
            logoView.heightAnchor.constraint(equalToConstant: 56),
            hStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            hStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -8),
            hStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, number: String?, logoURL: URL?) {
        nameLabel.text = name
        numberLabel.text = number
        numberLabel.isHidden = (number == nil)
        loadLogo(logoURL)
    }

    private func loadLogo(_ url: URL?) {
        let token = UUID()
        logoToken = token
        logoView.image = UIImage(systemName: "tv")
        guard let url else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.logoToken == token else { return }
                self.logoView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoToken = UUID()
        logoView.image = UIImage(systemName: "tv")
    }
}

// MARK: - Time header content (placed inside a sync scroll view)

/// Tick labels across the timeline. The view controller hosts this inside a
/// horizontally-scrolling, non-focusable container whose offset is synced to
/// the program grid.
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
