import Foundation

/// User-facing release notes. Newest first.
///
/// When you ship a new version: add a new entry at the top of
/// `entries`. The WhatsNewView modal will fire on the first launch
/// after the user updates, and the same entries are listed in
/// Settings → "What's New" for browsing later.
///
/// Keep highlights short and concrete — bullet items, not paragraphs.
/// Group by kind: `.new` for fresh features, `.improve` for noticeable
/// quality-of-life upgrades, `.fix` for user-visible bug fixes that
/// previously affected behaviour.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        // MARK: 0.4.0
        ChangelogEntry(
            version: "0.4.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.topshelf.title",
                    "changelog.0_4_0.topshelf.body",
                    icon: "rectangle.stack.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.siri.title",
                    "changelog.0_4_0.siri.body",
                    icon: "waveform"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_0.episodeImages.title",
                    "changelog.0_4_0.episodeImages.body",
                    icon: "photo.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.tintButtons.title",
                    "changelog.0_4_0.tintButtons.body",
                    icon: "paintpalette.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.cardHeights.title",
                    "changelog.0_4_0.cardHeights.body",
                    icon: "rectangle.grid.3x2.fill"
                ),
            ]
        ),
    ]

    /// The newest release. Used by WhatsNewView for the post-update
    /// modal and by the version-tracking preference to decide
    /// whether to show it.
    static var latest: ChangelogEntry? {
        entries.first
    }
}
