import SwiftUI

struct AppearanceSettingsView: View {

    @Environment(\.dependencies) private var dependencies

    private var appearance: AppearancePreferences { dependencies.appearancePreferences }
    private var isSupporter: Bool { dependencies.storeKitService.isSupporter }
    private var effectiveTheme: ResolvedAppearanceTheme {
        appearance.resolvedTheme(isSupporter: isSupporter)
    }

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

                header
                togglesSection
                personalizationSection
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
                defaultValue: "Customize content, accent color, and background."
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

    private var personalizationSection: some View {
        VStack(spacing: 4) {
            NavigationLink {
                AccentColorPickerView(initialCategory: appearance.accentChoice.category)
            } label: {
                AppearanceNavigationRow(
                    icon: "paintpalette.fill",
                    title: String(localized: "appearance.accentPicker.title",
                                  defaultValue: "Accent Color"),
                    value: effectiveTheme.accent.title
                ) {
                    Circle()
                        .fill(effectiveTheme.palette.control.color)
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                }
            }
            .buttonStyle(SettingsTileButtonStyle())

            NavigationLink {
                BackgroundPickerView()
            } label: {
                AppearanceNavigationRow(
                    icon: "rectangle.inset.filled",
                    title: String(localized: "appearance.backgroundPicker.title",
                                  defaultValue: "Background"),
                    value: effectiveTheme.background.title
                ) {
                    AppBackgroundView(
                        theme: effectiveTheme,
                        mode: .static
                    )
                    .frame(width: 52, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                }
            }
            .buttonStyle(SettingsTileButtonStyle())
        }
    }
}

private struct AppearanceNavigationRow<Preview: View>: View {
    let icon: String
    let title: String
    let value: String
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 34)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            preview()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .contentShape(Rectangle())
    }
}
