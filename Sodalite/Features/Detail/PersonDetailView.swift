import SwiftUI

/// Person page: photo, biography, filmography grid. A filmography tap routes to Jellyfin detail when the library owns the title, else to Seerr detail to request it.
struct PersonDetailView: View {
    /// TMDB id when the caller already knows it (Seerr cast); nil for Jellyfin cast, where `load()`
    /// translates `jellyfinPersonID` first and the wait sits behind this view's own spinner.
    let personID: Int?
    let jellyfinPersonID: String?
    /// Shown in the header until the detail fetch lands; pass "" if unknown.
    let personName: String

    init(personID: Int?, jellyfinPersonID: String? = nil, personName: String) {
        self.personID = personID
        self.jellyfinPersonID = jellyfinPersonID
        self.personName = personName
    }

    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var detail: SeerrPersonDetail?
    /// Kept so the error state's retry button does not pay for the id translation a second time.
    @State private var resolvedTMDBID: Int?
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
            .themedStaticBackground()
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
            // The name is all this view knows before the fetches land, and showing it makes the
            // push read as "this person is opening" rather than as a blank screen.
            VStack(spacing: 20) {
                ProgressView()
                if !personName.isEmpty {
                    Text(personName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
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
        // The hero needs 400px+ on every tier (140pt at 3x on a phone, 200pt at 2x on a 4K TV),
        // so w185 was always an upscale here.
        let photo = AsyncCachedImage(
            url: SeerrImageURL.profile(path: detail?.profilePath, size: .h632)
        ) { image in
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
        guard let tmdbID = await personTMDBID() else {
            errorMessage = String(
                localized: "person.noTmdbID",
                defaultValue: "This cast member has no TMDB id on the server, so there is no person page to show."
            )
            return
        }
        do {
            async let d = dependencies.seerrMediaService.personDetail(tmdbID: tmdbID)
            async let c = dependencies.seerrMediaService.personCredits(tmdbID: tmdbID)
            detail = try await d
            filmography = Self.computeFilmography(from: try await c)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Jellyfin's item response carries no provider ids for cast, so a Jellyfin-sourced person costs
    /// one lookup to reach TMDB. Runs inside `load()` so the spinner covers it.
    private func personTMDBID() async -> Int? {
        if let personID { return personID }
        if let resolvedTMDBID { return resolvedTMDBID }
        guard let jellyfinPersonID, let userID = appState.activeUser?.id else { return nil }
        let person = try? await dependencies.jellyfinItemService.getItemDetail(
            userID: userID, itemID: jellyfinPersonID
        )
        resolvedTMDBID = person?.tmdbID
        return resolvedTMDBID
    }

    /// Owned in Jellyfin routes to play; else to Seerr request. The library lookup runs only when Seerr marks the title available, so non-owned titles skip the query.
    private func handleTap(_ media: SeerrMedia) {
        Task {
            let status = media.mediaInfo?.status
            if status == .available || status == .partiallyAvailable,
               let userID = appState.activeUser?.id,
               let item = try? await dependencies.jellyfinItemService.findByTmdbID(
                   userID: userID, tmdbID: media.id, searchTerm: media.displayTitle
               ) {
                navigateToJellyfinItem = item
                return
            }
            navigateToSeerrMedia = media
        }
    }
}
