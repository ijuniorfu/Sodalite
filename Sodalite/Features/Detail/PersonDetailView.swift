import SwiftUI

/// Person page: photo, biography, filmography grid. A filmography tap routes to Jellyfin detail when the library owns the title, else to Seerr detail to request it.
struct PersonDetailView: View {
    let personID: Int
    /// Shown in the header until the detail fetch lands; pass "" if unknown.
    let personName: String

    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var detail: SeerrPersonDetail?
    /// Deduped/sorted filmography, computed once from the person credits in `load()`.
    @State private var filmography: [SeerrMedia] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var navigateToJellyfinItem: JellyfinItem?
    @State private var navigateToSeerrMedia: SeerrMedia?

    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }

    /// tvOS keeps the fixed five-up filmography grid; iOS/iPadOS wrap to as many adaptive columns as the width fits (fixed-five overflows an iPad in portrait).
    private var columns: [GridItem] {
        #if os(tvOS)
        return Array(repeating: GridItem(.fixed(220), spacing: 32), count: 5)
        #else
        return [GridItem(.adaptive(minimum: metrics.gridMinimum), spacing: metrics.gridSpacing)]
        #endif
    }

    var body: some View {
        content
            // No hero backdrop, so the shared grey-glass page background, not flat black.
            // glassBackground already bleeds its material past the safe area; the content itself must
            // respect it, else the header photo starts under the status bar / notch and gets clipped.
            .glassBackground()
            .hidesShellTabBar()
        .navigationDestination(item: $navigateToJellyfinItem) { item in
            DetailRouterView(item: item)
        }
        .navigationDestination(item: $navigateToSeerrMedia) { media in
            CatalogDetailView(media: media)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            errorState(message: errorMessage)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    if let bio = detail?.biography, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("person.biography")
                                .font(.title3)
                                .fontWeight(.semibold)
                            ExpandableTextBox(text: bio)
                        }
                    }

                    filmographySection
                }
                .padding(.horizontal, hSizeClass == .compact ? metrics.gridInset : 80)
                .padding(.vertical, hSizeClass == .compact ? 24 : 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        // Compact stacks the photo above the name so neither gets squeezed on a phone; wider tiers keep the side-by-side hero.
        let photoSide: CGFloat = hSizeClass == .compact ? 140 : 200
        let photo = AsyncCachedImage(url: SeerrImageURL.profile(path: detail?.profilePath)) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Text(initials)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: photoSide, height: photoSide)
        .clipShape(Circle())

        let nameBlock = VStack(alignment: .leading, spacing: 8) {
            Text(displayName)
                .font(.largeTitle)
                .fontWeight(.bold)

            if let dept = detail?.knownForDepartment, !dept.isEmpty {
                Text(verbatim: "\(String(localized: "person.knownFor", defaultValue: "Known for")): \(dept)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }

        return Group {
            if hSizeClass == .compact {
                VStack(alignment: .leading, spacing: 16) {
                    photo
                    nameBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 32) {
                    photo
                    nameBlock
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("person.filmography")
                .font(.title3)
                .fontWeight(.semibold)

            if filmography.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("person.noTitles")
                        .foregroundStyle(.secondary)
                    Button {
                        dismiss()
                    } label: {
                        Text("common.back")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                }
            } else {
                LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                    // stableKey, not Identifiable's id: a filmography mixes
                    // movie and tv credits whose TMDB ids can collide.
                    ForEach(filmography, id: \.stableKey) { media in
                        FocusableCard {
                            handleTap(media)
                        } content: { focused in
                            SeerrMediaCard(media: media, isFocused: focused)
                        }
                    }
                }
            }
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            HStack(spacing: 16) {
                Button {
                    Task { await load() }
                } label: {
                    Text("home.retry")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(SettingsTileButtonStyle())
                Button {
                    dismiss()
                } label: {
                    Text("common.back")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                }
                .buttonStyle(SettingsTileButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, hSizeClass == .compact ? metrics.gridInset : 80)
    }

    // MARK: - Derived

    private var displayName: String {
        detail?.name ?? (personName.isEmpty ? " " : personName)
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(displayName.prefix(2)).uppercased()
    }

    /// cast + crew, deduped by stableKey, poster-only, newest first. Computed once when credits load
    /// (see `load()`) and cached in `filmography`, rather than re-deduped/re-sorted on every body pass.
    private static func computeFilmography(from credits: SeerrPersonCredits?) -> [SeerrMedia] {
        let all = (credits?.cast ?? []) + (credits?.crew ?? [])
        var seen = Set<String>()
        let deduped = all.filter { seen.insert($0.stableKey).inserted }
        return deduped
            .filter { $0.posterPath != nil }
            .sorted {
                ($0.releaseDate ?? $0.firstAirDate ?? "")
                    > ($1.releaseDate ?? $1.firstAirDate ?? "")
            }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard appState.isSeerrConnected else {
            errorMessage = String(
                localized: "person.seerrNotConnected",
                defaultValue: "Seerr is not connected. Connect Seerr in Settings to view this page."
            )
            return
        }
        do {
            async let d = dependencies.seerrMediaService.personDetail(tmdbID: personID)
            async let c = dependencies.seerrMediaService.personCredits(tmdbID: personID)
            detail = try await d
            filmography = Self.computeFilmography(from: try await c)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Owned in Jellyfin routes to play; else to Seerr request. The library lookup runs only when Seerr marks the title available, so non-owned titles skip the query.
    private func handleTap(_ media: SeerrMedia) {
        Task {
            let status = media.mediaInfo?.status
            if status == .available || status == .partiallyAvailable,
               let userID = appState.activeUser?.id,
               let item = try? await dependencies.jellyfinItemService.findByTmdbID(
                   userID: userID, tmdbID: media.id
               ) {
                navigateToJellyfinItem = item
                return
            }
            navigateToSeerrMedia = media
        }
    }
}
