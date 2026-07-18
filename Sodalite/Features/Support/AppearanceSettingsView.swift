import SwiftUI

/// Accent picker gated behind Supporter Pack; locked state grays swatches + CTA to Support screen.
struct AppearanceSettingsView: View {

    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }
    private var isSupporter: Bool { dependencies.storeKitService.isSupporter }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text(String(
                    localized: "settings.appearance.title",
                    defaultValue: "Appearance"
                ))
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)

                togglesSection

                header
                if isSupporter {
                    accentPicker
                } else {
                    lockedCard
                }
            }
            .screenContentInset()
        }
        // Inline largeTitle only; floating nav-title otherwise sits behind scroll content. Matches PlaybackSettingsView.
        .hidesNavigationBarChrome()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(String(
                localized: "settings.appearance.subtitle",
                defaultValue: "How logos, cards, and images look, plus the accent color."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Options (free for everyone)

    /// Free rows above the supporter-gated accent picker; same ValuePickerRow as Playback for consistency.
    private var togglesSection: some View {
        VStack(spacing: 4) {
            boolRow(
                icon: "photo.on.rectangle",
                title: "settings.appearance.showLogos",
                subtitle: "settings.appearance.showLogos.subtitle",
                value: Binding(get: { appearance.showContentLogos },
                               set: { appearance.showContentLogos = $0 })
            )

            ValuePickerRow(
                icon: "rectangle.on.rectangle.angled",
                title: "settings.appearance.cwImage",
                subtitle: "settings.appearance.cwImage.subtitle",
                options: AppearancePreferences.ContinueWatchingImage.allCases,
                selection: Binding(get: { appearance.continueWatchingImage },
                                   set: { appearance.continueWatchingImage = $0 }),
                label: { $0.title }
            )

            boolRow(
                icon: "rectangle.expand.vertical",
                title: "settings.appearance.largeCards",
                subtitle: "settings.appearance.largeCards.subtitle",
                value: Binding(get: { appearance.largeCards },
                               set: { appearance.largeCards = $0 })
            )

            boolRow(
                icon: "music.note.tv",
                title: "settings.appearance.nowPlayingPoster",
                subtitle: "settings.appearance.nowPlayingPoster.subtitle",
                value: Binding(get: { appearance.nowPlayingUsesSeriesPoster },
                               set: { appearance.nowPlayingUsesSeriesPoster = $0 })
            )
        }
    }

    private func boolRow(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        value: Binding<Bool>
    ) -> some View {
        ValuePickerRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            options: [false, true],
            selection: value,
            label: { on in
                on
                    ? String(localized: "settings.playback.on", defaultValue: "On")
                    : String(localized: "settings.playback.off", defaultValue: "Off")
            }
        )
    }

    // MARK: - Picker

    private var accentPicker: some View {
        VStack(spacing: 4) {
            ForEach(AppearancePreferences.AccentChoice.allCases) { choice in
                AccentRow(
                    choice: choice,
                    isSelected: appearance.accentChoice == choice
                ) {
                    appearance.accentChoice = choice
                }
            }
        }
    }

    // MARK: - Locked state

    private var lockedCard: some View {
        VStack(spacing: 20) {
            // Centered flow so the ten swatches wrap AND each row stays centered. A fixed HStack was
            // ~508pt wide (10 x 40 + spacing), overflowing the iPhone content width and stretching the
            // whole screen's rows (the VStack sized to this widest child); an adaptive grid fixed the
            // overflow but left-aligned the last row. Wraps on iPhone, one centered row on tvOS/iPad.
            FlowLayout(alignment: .center, spacing: 12) {
                ForEach(AppearancePreferences.AccentChoice.allCases) { choice in
                    Circle()
                        .fill(choice.color)
                        .frame(width: 40, height: 40)
                        .opacity(0.35)
                }
            }

            VStack(spacing: 8) {
                Label(
                    String(localized: "settings.appearance.locked.title",
                           defaultValue: "Part of the Supporter Pack"),
                    systemImage: "lock.fill"
                )
                .font(.headline)

                Text(String(
                    localized: "settings.appearance.locked.subtitle",
                    defaultValue: "Unlock accent colors along with the premium splash icon and supporter badge."
                ))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            NavigationLink {
                SupportDevelopmentView()
                    .hidesShellTabBar()
            } label: {
                Text(String(
                    localized: "settings.appearance.locked.cta",
                    defaultValue: "Open Support Development"
                ))
                .font(.body)
                .fontWeight(.medium)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.05))
        )
    }
}

// MARK: - Accent Row

private struct AccentRow: View {
    let choice: AppearancePreferences.AccentChoice
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button(action: action) {
            HStack(spacing: 28) {
                Circle()
                    .fill(choice.color)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.15), lineWidth: 1)
                    )

                Text(choice.title)
                    .font(.body)
                    .fontWeight(.medium)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
    }
}
