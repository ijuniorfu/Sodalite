import SwiftUI

enum BackgroundPickerLayout {
    static let tvOSColumnCount = 3
    static let columnSpacing: CGFloat = 24
    static let previewAspectRatio: CGFloat = 16.0 / 9.0
    static let tvOSMetadataHeight: CGFloat = 144
    static let iOSMetadataHeight: CGFloat = 68

    #if os(tvOS)
    static let metadataHeight = tvOSMetadataHeight
    #else
    static let metadataHeight = iOSMetadataHeight
    #endif
}

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
        #if os(tvOS)
        Array(
            repeating: GridItem(
                .flexible(),
                spacing: BackgroundPickerLayout.columnSpacing,
                alignment: .top
            ),
            count: BackgroundPickerLayout.tvOSColumnCount
        )
        #else
        [GridItem(.adaptive(
            minimum: horizontalSizeClass == .compact ? 155 : 280,
            maximum: 360
        ), spacing: 20, alignment: .top)]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text(String(
                    localized: "appearance.backgroundPicker.title",
                    defaultValue: "Background"
                ))
                .font(.largeTitle.bold())

                LazyVGrid(
                    columns: columns,
                    spacing: BackgroundPickerLayout.columnSpacing
                ) {
                    ForEach(BackgroundStyle.allCases) { style in
                        FocusableCard(
                            action: { select(style) },
                            highlightsOnPress: true,
                            exposesButtonSemantics: true
                        ) { focused in
                            BackgroundStyleTile(
                                style: style,
                                accent: theme.accent,
                                controlColor: theme.palette.control.color,
                                selected: preferences.backgroundStyle == style,
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

    private func select(_ style: BackgroundStyle) {
        if style.tier == .supporter && !isSupporter {
            requestSupportAccess()
        } else {
            preferences.backgroundStyle = style
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
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppBackgroundView(
                theme: ResolvedAppearanceTheme(accent: accent, background: style),
                mode: focused && style.tier == .supporter ? .preview : .static
            )
            .aspectRatio(
                BackgroundPickerLayout.previewAspectRatio,
                contentMode: .fit
            )
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 8) {
                Text(style.title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if style.tier == .supporter {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } else {
                        Text(String(
                            localized: "appearance.free",
                            defaultValue: "Free"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .frame(
                height: BackgroundPickerLayout.metadataHeight,
                alignment: .top
            )
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
        let supporterLabel = String(
            localized: "settings.appearance.locked.title",
            defaultValue: "Part of the Supporter Pack"
        )
        let freeLabel = String(
            localized: "appearance.free",
            defaultValue: "Free"
        )
        let tierLabel = style.tier == .supporter ? supporterLabel : freeLabel
        return [selected ? selectedLabel : nil, tierLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
