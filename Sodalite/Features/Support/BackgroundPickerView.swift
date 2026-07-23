import SwiftUI

struct BackgroundPickerView: View {
    @Environment(\.appearanceTheme) private var theme
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSupport = false

    private var preferences: AppearancePreferences {
        dependencies.appearancePreferences
    }

    private var isSupporter: Bool {
        dependencies.storeKitService.isSupporter
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(
            minimum: horizontalSizeClass == .compact ? 155 : 280,
            maximum: 360
        ), spacing: 20)]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text(String(
                    localized: "appearance.backgroundPicker.title",
                    defaultValue: "Background"
                ))
                .font(.largeTitle.bold())

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(BackgroundStyle.allCases) { style in
                        FocusableCard {
                            if style.tier == .supporter && !isSupporter {
                                requestSupportAccess()
                            } else {
                                preferences.backgroundStyle = style
                            }
                        } content: { focused in
                            BackgroundStyleTile(
                                style: style,
                                accent: theme.accent,
                                controlColor: theme.palette.control.color,
                                selected: preferences.backgroundStyle == style,
                                locked: style.tier == .supporter && !isSupporter,
                                focused: focused
                            )
                        }
                    }
                }
            }
            .screenContentInset()
        }
        .hidesNavigationBarChrome()
        .navigationDestination(isPresented: $showSupport) {
            SupportDevelopmentView()
                .hidesShellTabBar()
        }
    }

    private func requestSupportAccess() {
        guard dependencies.parentalGateRequiredForSessionAction() else {
            showSupport = true
            return
        }

        Task {
            guard await dependencies.parentalGate.challenge(
                reason: .openParentalSettings
            ) else { return }
            showSupport = true
        }
    }
}

private struct BackgroundStyleTile: View {
    let style: BackgroundStyle
    let accent: AccentPreset
    let controlColor: Color
    let selected: Bool
    let locked: Bool
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppBackgroundView(
                theme: ResolvedAppearanceTheme(accent: accent, background: style),
                mode: focused ? .preview : .static
            )
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack {
                Text(style.title).font(.headline)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
                if locked {
                    Image(systemName: "crown.fill").foregroundStyle(.secondary)
                }
                if !selected && !locked {
                    Text(String(localized: "appearance.free", defaultValue: "Free"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(focused ? 0.12 : 0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(selected ? controlColor : .clear, lineWidth: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(Text(accessibilityValue))
    }

    private var accessibilityValue: String {
        let selectedLabel = String(
            localized: "appearance.selected",
            defaultValue: "Selected"
        )
        let lockedLabel = String(
            localized: "settings.appearance.locked.title",
            defaultValue: "Part of the Supporter Pack"
        )
        return [selected ? selectedLabel : nil, locked ? lockedLabel : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
