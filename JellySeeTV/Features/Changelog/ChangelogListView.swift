import SwiftUI

/// Settings → "What's New" entry. Lists every shipped release with
/// its highlights so users can browse history any time, not just
/// in the post-update moment. Uses the same row visual as the
/// WhatsNewView modal — single source of truth for highlight
/// rendering would be nice, but keeping them as parallel views
/// avoids over-binding the Settings layout to a modal-shaped
/// component.
struct ChangelogListView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(String(
                    localized: "settings.changelog.title",
                    defaultValue: "What's New"
                ))
                .font(.largeTitle)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
                .padding(.bottom, 32)

                LazyVStack(spacing: 56) {
                    ForEach(Changelog.entries) { entry in
                        VersionSection(entry: entry)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 80)
                .padding(.bottom, 80)
            }
            .frame(maxWidth: .infinity)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct VersionSection: View {
    let entry: ChangelogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // "Version 0.4.0" — keep the literal "Version" prefix
            // verbatim so we don't have to ship a catalog entry for
            // every language; "Version" reads correctly in every
            // shipped locale.
            Text("Version \(entry.version)")
                .font(.title2)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(entry.highlights) { highlight in
                    HighlightRow(highlight: highlight)
                }
            }
        }
    }
}

private struct HighlightRow: View {
    let highlight: ChangelogHighlight

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                Circle()
                    .fill(tintForKind.opacity(0.18))
                Image(systemName: highlight.systemImage)
                    .font(.title3)
                    .foregroundStyle(tintForKind)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title)
                    .font(.body)
                    .fontWeight(.semibold)
                if let description = highlight.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var tintForKind: Color {
        switch highlight.kind {
        case .new: return .blue
        case .improve: return .green
        case .fix: return .orange
        }
    }
}
