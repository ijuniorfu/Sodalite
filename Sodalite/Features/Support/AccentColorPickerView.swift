import SwiftUI

enum AccentPickerLayout {
    /// Every category ships at most five presets, so a fixed column count keeps
    /// the tiles at one size across category switches and gives the titles the
    /// full row width instead of the 219pt an adaptive grid settles on.
    static let tvOSColumnCount = 5

    #if os(tvOS)
    static let columnSpacing: CGFloat = 24
    static let swatchSize: CGFloat = 80
    /// Two lines of tvOS headline (38pt) plus leading.
    static let titleHeight: CGFloat = 96
    /// Two lines of tvOS caption (25pt).
    static let statusHeight: CGFloat = 64
    #else
    static let columnSpacing: CGFloat = 18
    static let swatchSize: CGFloat = 64
    static let titleHeight: CGFloat = 46
    static let statusHeight: CGFloat = 34
    #endif
}

struct AccentColorPickerView: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var category: AccentCategory
    @State private var showSupport = false

    init(initialCategory: AccentCategory) {
        _category = State(initialValue: initialCategory)
    }

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
                spacing: AccentPickerLayout.columnSpacing,
                alignment: .top
            ),
            count: AccentPickerLayout.tvOSColumnCount
        )
        #else
        [GridItem(
            .adaptive(
                minimum: horizontalSizeClass == .compact ? 130 : 190,
                maximum: 260
            ),
            spacing: AccentPickerLayout.columnSpacing,
            alignment: .top
        )]
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text(String(
                    localized: "appearance.accentPicker.title",
                    defaultValue: "Accent Color"
                ))
                .font(.largeTitle.bold())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(AccentCategory.allCases) { candidate in
                            AccentCategoryButton(
                                category: candidate,
                                selected: category == candidate
                            ) {
                                category = candidate
                            }
                        }
                    }
                }

                LazyVGrid(
                    columns: columns,
                    spacing: AccentPickerLayout.columnSpacing
                ) {
                    ForEach(category.presets) { preset in
                        FocusableCard(
                            action: {
                                if preset.tier == .supporter && !isSupporter {
                                    requestSupportAccess()
                                } else {
                                    preferences.accentChoice = preset
                                }
                            },
                            exposesButtonSemantics: true
                        ) { focused in
                            AccentPresetTile(
                                preset: preset,
                                selected: preferences.accentChoice == preset,
                                locked: preset.tier == .supporter && !isSupporter,
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
                .themedNavigationDestination()
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

private struct AccentCategoryButton: View {
    let category: AccentCategory
    let selected: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        label
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(focused ? .white.opacity(0.15) : .white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(focused ? 1 : 0)
            )
            .scaleEffect(focused ? 1.03 : 1.0)
            .focusable(true)
            .focused($focused)
            .stableTap(isFocused: focused, perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { action() }
            .animation(.easeInOut(duration: 0.2), value: focused)
        #else
        Button(action: action) {
            label
        }
        .buttonStyle(SettingsTileButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        #endif
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(category.title)
            if category != .basic {
                Image(systemName: "crown.fill")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct AccentPresetTile: View {
    let preset: AccentPreset
    let selected: Bool
    let locked: Bool
    let focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(preset.palette.control.color)
                .frame(
                    width: AccentPickerLayout.swatchSize,
                    height: AccentPickerLayout.swatchSize
                )
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            Text(preset.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(height: AccentPickerLayout.titleHeight, alignment: .top)
            VStack(spacing: 4) {
                if selected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text(selectedLabel)
                    }
                }
                if locked {
                    HStack(spacing: 6) {
                        Image(systemName: "crown.fill")
                        Text(lockedLabel)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .frame(height: AccentPickerLayout.statusHeight, alignment: .top)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(focused ? 0.12 : 0.05))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    selected ? preset.palette.control.color : .clear,
                    lineWidth: 3
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(Text(accessibilityValue))
    }

    private var selectedLabel: String {
        String(localized: "appearance.selected", defaultValue: "Selected")
    }

    private var lockedLabel: String {
        String(
            localized: "settings.appearance.locked.title",
            defaultValue: "Part of the Supporter Pack"
        )
    }

    private var accessibilityValue: String {
        [selected ? selectedLabel : nil, locked ? lockedLabel : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
