import SwiftUI

/// Accent-color picker, gated behind the Supporter Pack. Locked state
/// shows the swatches grayed-out with a CTA that jumps to the Support
/// Development screen instead of letting the user tap a row.
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
            .padding(.vertical, 60)
            .padding(.horizontal, 80)
        }
        // Inline largeTitle only; the floating nav-title otherwise
        // sits behind the scroll content. Matches PlaybackSettingsView.
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text(String(
                localized: "settings.appearance.subtitle",
                defaultValue: "Pick an accent color for buttons, focus rings, and highlights."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 720)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Toggles (free for everyone)

    /// Free customization toggles, above the supporter-gated accent picker.
    private var togglesSection: some View {
        VStack(spacing: 4) {
            toggleRow(
                icon: "photo.on.rectangle",
                title: String(localized: "settings.appearance.showLogos",
                              defaultValue: "Show content logos"),
                subtitle: String(localized: "settings.appearance.showLogos.subtitle",
                                 defaultValue: "Use a show or movie's logo image instead of its text title on the detail screens, when one is available."),
                isOn: appearance.showContentLogos
            ) { appearance.showContentLogos.toggle() }

            toggleRow(
                icon: "rectangle.on.rectangle.angled",
                title: String(localized: "settings.appearance.cwSeriesArt",
                              defaultValue: "Series art for Continue Watching"),
                subtitle: String(localized: "settings.appearance.cwSeriesArt.subtitle",
                                 defaultValue: "Show the show's landscape artwork in Continue Watching and Up Next instead of the episode's video frame."),
                isOn: appearance.continueWatchingUsesSeriesArt
            ) { appearance.continueWatchingUsesSeriesArt.toggle() }

            toggleRow(
                icon: "rectangle.expand.vertical",
                title: String(localized: "settings.appearance.largeCards",
                              defaultValue: "Larger cards"),
                subtitle: String(localized: "settings.appearance.largeCards.subtitle",
                                 defaultValue: "Render Home cards bigger, Apple TV style. Fewer cards fit per row."),
                isOn: appearance.largeCards
            ) { appearance.largeCards.toggle() }

            toggleRow(
                icon: "music.note.tv",
                title: String(localized: "settings.appearance.nowPlayingPoster",
                              defaultValue: "Series poster in Now Playing"),
                subtitle: String(localized: "settings.appearance.nowPlayingPoster.subtitle",
                                 defaultValue: "Use the series poster instead of the episode still for the Control Center artwork."),
                isOn: appearance.nowPlayingUsesSeriesPoster
            ) { appearance.nowPlayingUsesSeriesPoster.toggle() }
        }
    }

    private func toggleRow(
        icon: String,
        title: String,
        subtitle: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 28) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Text(isOn
                     ? String(localized: "settings.playback.on", defaultValue: "On")
                     : String(localized: "settings.playback.off", defaultValue: "Off"))
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
            }
            .padding(20)
        }
        .buttonStyle(SettingsTileButtonStyle())
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
            HStack(spacing: 12) {
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
                    .toolbar(.hidden, for: .tabBar)
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
