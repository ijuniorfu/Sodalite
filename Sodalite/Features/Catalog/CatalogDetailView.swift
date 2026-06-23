import SwiftUI

struct CatalogDetailView: View {
    let media: SeerrMedia
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var movieDetail: SeerrMovieDetail?
    @State private var tvDetail: SeerrTVDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var selectedSeasons: Set<Int> = []
    @State private var isSubmitting = false
    @State private var didRequest = false
    @State private var requestError: String?

    /// Currently-viewed season; independent of the request set so the user can browse episodes without requesting.
    @State private var viewedSeasonNumber: Int?
    /// Per-season episode cache, lazily populated and kept for the view's lifetime.
    @State private var seasonEpisodes: [Int: [SeerrEpisode]] = [:]
    /// Per-season in-flight markers driving the episode-strip spinner.
    @State private var loadingSeasons: Set<Int> = []

    /// Jellyfin ground-truth reconcile of Seerr's cached availability. Seerr's mediaInfo.status stays "available" after a Radarr/Sonarr deletion until its ~6h availability-sync runs; Sodalite is the Jellyfin client, so it cross-checks the library directly and overrides stale "available" with .deleted. .unknown = trust Seerr (no Jellyfin user, lookup failed, or Seerr never claimed availability).
    @State private var titlePresence: JellyfinPresence = .unknown
    /// Per-season episode-file presence in Jellyfin (seasonNumber -> hasFiles); nil until the reconcile runs for a present series. A Seerr-available season absent here (or false) was deleted server-side.
    @State private var jellyfinSeasonHasFiles: [Int: Bool]?

    /// Recommendations (falling back to similar), loaded in parallel with the detail so the screen paints first.
    @State private var recommendations: [SeerrMedia] = []
    /// Rotten Tomatoes critics score, best-effort from Seerr's ratings endpoint; nil on older server / no RT data.
    @State private var rtCriticsScore: Int?
    @State private var navigateToMedia: SeerrMedia?
    @State private var selectedCastMember: CastMember?

    // Advanced request options from /service/radarr|sonarr; nil = omit field, falls back to Seerr's server default.
    @State private var serviceDetails: SeerrServiceDetails?
    @State private var selectedProfileID: Int?
    @State private var selectedRootFolder: String?
    /// Sonarr/Radarr tag ids; sent as nil when empty so older Jellyseerr builds that don't know the field still accept the body.
    @State private var selectedTagIDs: Set<Int> = []

    /// Picker sheets use `.fullScreenCover` not SwiftUI `Menu`: Menu leaked the Menu-button press up the nav stack during its ~1s close animation and exited the app; the cover owns its own focus environment.
    @State private var isProfilePickerPresented = false
    @State private var isRootFolderPickerPresented = false
    @State private var isTagPickerPresented = false

    /// Mandatory request-options sheet (quality profile, root folder, tags + final confirm).
    @State private var showRequestOptions = false

    /// First-screen focus. Seeded to `.request` once loaded so no focus lands below the fold and triggers an on-open auto-scroll (old tab-bar-stuck-hidden bug). Request with no seasons picked moves focus to `.seasons` to scroll the picker into view.
    @FocusState private var focusedField: DetailFocus?
    private enum DetailFocus: Hashable { case request, seasons }

    /// Result of the Jellyfin library cross-check. .unknown degrades to trusting Seerr; never a false .absent.
    private enum JellyfinPresence: Equatable { case unknown, present, absent }

    var body: some View {
        ZStack {
            DetailBackdrop(
                imageURL: SeerrImageURL.backdrop(path: backdropPath),
                posterFallbackURL: SeerrImageURL.poster(path: media.posterPath)
            )
                .id(backdropPath ?? "empty")

            content
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $navigateToMedia) { media in
            CatalogDetailView(media: media)
        }
        .navigationDestination(item: $selectedCastMember) { member in
            PersonDetailView(personID: member.personID ?? 0, personName: member.name)
        }
        .sheet(isPresented: $showRequestOptions) {
            requestOptionsSheet
        }
        .onChange(of: isLoading) { _, loading in
            // Focus the action button so nothing below the fold auto-scrolls; defer dodges the focus-commit race (as MovieDetailView).
            if loading == false {
                deferOnMain(by: 0.1) { focusedField = .request }
            }
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
            // Same shape as MovieDetailView: hero + bottom-aligned primary block fill screen one, rest scrolls below the fold; default focus stays in the visible block so opening never auto-scrolls (left the tab bar stuck hidden on mid-scroll back-out).
            DetailContentOverlay(hero: {
                heroTitle
            }, primary: {
                primaryBlock
            }) {
                trailingBody
            }
        }
    }

    private func errorState(message: String) -> some View {
        // tvOS Menu pops the nav level only with something focusable; a text-only error screen would exit the app instead. Retry/Back buttons claim focus and give a recovery path.
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
    }

    // MARK: - Hero + primary block (first screen)

    private var heroTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(displayTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
            if let year = displayYear {
                Text(year)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let status = mediaStatus, status != .unknown {
                SeerrStatusBadge(status: status)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // No extra horizontal padding: DetailContentOverlay's hero slot already insets by 50, lining up with the bubble and request button.
    }

    private var primaryBlock: some View {
        VStack(alignment: .leading, spacing: 24) {
            metadataBubble
            requestActionRow
        }
        .padding(.horizontal, 50)
    }

    /// Metadata in a frosted bubble (matching Home detail views); left edge at the primary padding (50), aligned with hero title and request button.
    private var metadataBubble: some View {
        VStack(alignment: .leading, spacing: 12) {
            SeerrMetadataRow(
                rating: metadataRating,
                runtimeMinutes: metadataRuntime,
                year: nil,
                certification: metadataCertification,
                rtCriticsScore: rtCriticsScore
            )
            if !genres.isEmpty {
                Text(genres.map(\.name).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
    }

    @ViewBuilder
    private var requestActionRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            if didRequest {
                // Post-request CTA: nothing else focusable, so give a back-to-catalog action (else tvOS Menu exits the app).
                GlassActionButton(
                    title: "catalog.request.sent",
                    systemImage: "checkmark.circle.fill",
                    action: { dismiss() }
                )
                .focused($focusedField, equals: .request)
            } else if media.mediaType == .movie || media.mediaType == .tv {
                GlassActionButton(
                    title: requestButtonTitle,
                    systemImage: "tray.and.arrow.down",
                    isProminent: true,
                    isLoading: isSubmitting,
                    action: { requestButtonTapped() }
                )
                .focused($focusedField, equals: .request)
                .disabled(isSubmitting)

                if let requestError {
                    Text(requestError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// Series with no seasons picked: drop focus into the season picker so the focus engine scrolls it into view; else present the options sheet.
    private func requestButtonTapped() {
        if media.mediaType == .tv, selectedSeasons.isEmpty {
            focusedField = .seasons
        } else {
            showRequestOptions = true
        }
    }

    // MARK: - Request options sheet

    private var requestOptionsSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(displayTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                // Empty for users without service options; confirm still submits with server defaults.
                advancedOptionsSection

                Button {
                    Task {
                        await submitRequest()
                        if didRequest { showRequestOptions = false }
                    }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Label(requestButtonTitle, systemImage: "tray.and.arrow.down")
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(SettingsTileButtonStyle())
                .disabled(isSubmitting || !canSubmit)

                if let requestError {
                    Text(requestError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(48)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Trailing (scrolls below the fold)

    private var trailingBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let overview, !overview.isEmpty {
                ExpandableTextBox(text: overview)
            }

            if media.mediaType == .tv, let seasons = availableSeasons, !seasons.isEmpty {
                seasonSelection(seasons: seasons)
            }

            if !castMembers.isEmpty {
                MediaCastRow(members: castMembers) { member in
                    if member.personID != nil {
                        selectedCastMember = member
                    }
                }
                .padding(.horizontal, -50)
            }

            if !regionWatchProviders.isEmpty {
                SeerrWatchProvidersRow(providers: regionWatchProviders)
                    .padding(.horizontal, -50)
            }

            if !recommendations.isEmpty {
                SeerrHorizontalMediaRow(
                    title: "detail.moreLikeThis",
                    items: recommendations,
                    onItemSelected: { navigateToMedia = $0 }
                )
                .padding(.horizontal, -50)
            }
        }
        .padding(.horizontal, 50)
    }

    @ViewBuilder
    private var advancedOptionsSection: some View {
        if let details = serviceDetails, !didRequest {
            VStack(alignment: .leading, spacing: 16) {
                Text("catalog.request.advanced")
                    .font(.title3)
                    .fontWeight(.semibold)

                // Stacked full-width: quality-profile names get long ("[German] HD Bluray + WEB") and wrap in a half-width column.
                profilePicker(details: details)
                rootFolderPicker(details: details)

                if let tags = details.tags, !tags.isEmpty {
                    tagPicker(tags: tags)
                }
            }
        }
    }

    private func profilePicker(details: SeerrServiceDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("catalog.request.qualityProfile")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isProfilePickerPresented = true
            } label: {
                HStack {
                    Text(selectedProfileName(details: details))
                        .fontWeight(.medium)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(CatalogPickerButtonStyle())
            .fullScreenCover(isPresented: $isProfilePickerPresented) {
                CatalogPickerSheet(
                    title: String(localized: "catalog.request.qualityProfile", defaultValue: "Quality profile"),
                    options: details.profiles.map { .init(id: "\($0.id)", label: $0.name) },
                    selectedID: selectedProfileID.map(String.init),
                    onSelect: { rawID in
                        if let id = Int(rawID) {
                            selectedProfileID = id
                        }
                        isProfilePickerPresented = false
                    },
                    onCancel: { isProfilePickerPresented = false }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func rootFolderPicker(details: SeerrServiceDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("catalog.request.rootFolder")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isRootFolderPickerPresented = true
            } label: {
                HStack {
                    Text(selectedRootFolder ?? String(localized: "catalog.request.rootFolder.default", defaultValue: "Default"))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(CatalogPickerButtonStyle())
            .fullScreenCover(isPresented: $isRootFolderPickerPresented) {
                CatalogPickerSheet(
                    title: String(localized: "catalog.request.rootFolder", defaultValue: "Root folder"),
                    options: details.rootFolders.map { .init(id: $0.path, label: $0.path) },
                    selectedID: selectedRootFolder,
                    onSelect: { path in
                        selectedRootFolder = path
                        isRootFolderPickerPresented = false
                    },
                    onCancel: { isRootFolderPickerPresented = false }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func selectedProfileName(details: SeerrServiceDetails) -> String {
        if let id = selectedProfileID,
           let profile = details.profiles.first(where: { $0.id == id }) {
            return profile.name
        }
        return String(localized: "catalog.request.qualityProfile.default", defaultValue: "Default")
    }

    private func tagPicker(tags: [SeerrTag]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("catalog.request.tags")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                isTagPickerPresented = true
            } label: {
                HStack {
                    Text(selectedTagsLabel(tags: tags))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(CatalogPickerButtonStyle())
            .fullScreenCover(isPresented: $isTagPickerPresented) {
                CatalogMultiSelectSheet(
                    title: String(localized: "catalog.request.tags", defaultValue: "Tags"),
                    options: tags.map { .init(id: "\($0.id)", label: $0.label) },
                    selectedIDs: Set(selectedTagIDs.map(String.init)),
                    onCommit: { ids in
                        selectedTagIDs = Set(ids.compactMap(Int.init))
                        isTagPickerPresented = false
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func selectedTagsLabel(tags: [SeerrTag]) -> String {
        if selectedTagIDs.isEmpty {
            return String(localized: "catalog.request.tags.none", defaultValue: "None")
        }
        let names = tags
            .filter { selectedTagIDs.contains($0.id) }
            .map(\.label)
        return names.joined(separator: ", ")
    }

    private func seasonSelection(seasons: [SeerrSeason]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("catalog.seasons.select")
                .font(.title3)
                .fontWeight(.semibold)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(seasons) { season in
                            CatalogSeasonTab(
                                season: season,
                                isViewed: viewedSeasonNumber == season.seasonNumber,
                                isSelectedForRequest: selectedSeasons.contains(season.seasonNumber),
                                availabilityStatus: seasonStatus(season),
                                action: { selectSeasonForViewing(season) }
                            )
                            .id(season.seasonNumber)
                            // Focus anchor for requestButtonTapped's no-seasons-picked path.
                            .applyIf(season.seasonNumber == seasons.first?.seasonNumber) {
                                $0.focused($focusedField, equals: .seasons)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewedSeasonNumber) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }

            // Per-season + select-all actions below the tab row so tabs aren't sharing a horizontal focus slice with competing targets.
            seasonActionsRow(seasons: seasons)

            if let viewed = viewedSeasonNumber,
               let season = seasons.first(where: { $0.seasonNumber == viewed }) {
                seasonDetailBlock(season: season)
            }
        }
    }

    @ViewBuilder
    private func seasonActionsRow(seasons: [SeerrSeason]) -> some View {
        let viewedSeason: SeerrSeason? = viewedSeasonNumber.flatMap { n in
            seasons.first(where: { $0.seasonNumber == n })
        }
        HStack(spacing: 12) {
            if let season = viewedSeason {
                // Status is informational and never blocks: show the pipeline state (if any) as a label, then always offer add/remove so a deleted-but-stale-available season stays re-requestable.
                if let status = seasonStatus(season) {
                    Label(
                        seasonStatusLabel(status),
                        systemImage: status.systemImage
                    )
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                let isSelected = selectedSeasons.contains(season.seasonNumber)
                Button {
                    toggleSeason(season)
                } label: {
                    Label(
                        isSelected
                            ? "catalog.seasons.removeFromRequest"
                            : "catalog.seasons.addToRequest",
                        systemImage: isSelected ? "checkmark.circle.fill" : "plus.circle"
                    )
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(SeasonChipButtonStyle())
            }
            if hasSelectableSeasons(in: seasons) {
                Button {
                    toggleAllSeasons(seasons)
                } label: {
                    Label(
                        allSelectableSeasonsSelected(in: seasons)
                            ? "catalog.seasons.deselectAll"
                            : "catalog.seasons.selectAll",
                        systemImage: allSelectableSeasonsSelected(in: seasons)
                            ? "minus.circle"
                            : "plus.circle"
                    )
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(SeasonChipButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func seasonDetailBlock(season: SeerrSeason) -> some View {
        let n = season.seasonNumber
        let episodes = seasonEpisodes[n]

        VStack(alignment: .leading, spacing: 12) {
            // Heading only; the per-season Add / Already-Available action moved up by the tab row to share a focus column with Select All.
            Text(seasonHeading(season: season))
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 4)

            if let overview = season.overview, !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 4)
            }

            if loadingSeasons.contains(n) && (episodes?.isEmpty ?? true) {
                HStack {
                    ProgressView()
                    Spacer()
                }
                .frame(height: 220)
                .padding(.horizontal, 20)
            } else if let episodes, !episodes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 24) {
                        ForEach(episodes) { ep in
                            FocusableCard(action: {}) { focused in
                                SeerrEpisodeCard(episode: ep, isFocused: focused)
                            }
                            .id("\(n)-\(ep.episodeNumber)")
                        }
                    }
                    .padding(.horizontal, 20)
                    // Room for the focused card's scale (1.04) + drop shadow (radius 14, y 6) the ScrollView would otherwise clip.
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            } else if !loadingSeasons.contains(n) {
                Text("catalog.seasons.noEpisodes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 4)
    }

    private func seasonHeading(season: SeerrSeason) -> String {
        let label = String(localized: "catalog.season", defaultValue: "Season")
        if let name = season.name, !name.isEmpty, name != "\(label) \(season.seasonNumber)" {
            return "\(label) \(season.seasonNumber) · \(name)"
        }
        return "\(label) \(season.seasonNumber)"
    }

    private func selectSeasonForViewing(_ season: SeerrSeason) {
        let n = season.seasonNumber
        viewedSeasonNumber = n
        guard seasonEpisodes[n] == nil, !loadingSeasons.contains(n) else { return }
        Task { await loadSeasonEpisodes(seasonNumber: n) }
    }

    private func loadSeasonEpisodes(seasonNumber: Int) async {
        guard let tvID = tvDetail?.id else { return }
        loadingSeasons.insert(seasonNumber)
        defer { loadingSeasons.remove(seasonNumber) }
        do {
            let detail = try await dependencies.seerrMediaService.tvSeasonDetail(
                tmdbID: tvID,
                seasonNumber: seasonNumber
            )
            seasonEpisodes[seasonNumber] = detail.episodes ?? []
        } catch {
            // Best-effort: leave the cache empty so "no episodes" renders; a banner would compete with the request-error label.
        }
    }

    private func selectableSeasons(in seasons: [SeerrSeason]) -> [SeerrSeason] {
        // Status never gates a request: a season deleted in Radarr/Sonarr (server reports it stale-available) must stay re-requestable, so every real season is selectable and status is display-only.
        seasons
    }

    private func hasSelectableSeasons(in seasons: [SeerrSeason]) -> Bool {
        !selectableSeasons(in: seasons).isEmpty
    }

    private func allSelectableSeasonsSelected(in seasons: [SeerrSeason]) -> Bool {
        let selectable = selectableSeasons(in: seasons)
        guard !selectable.isEmpty else { return false }
        return selectable.allSatisfy { selectedSeasons.contains($0.seasonNumber) }
    }

    private func toggleAllSeasons(_ seasons: [SeerrSeason]) {
        let selectable = selectableSeasons(in: seasons)
        if allSelectableSeasonsSelected(in: seasons) {
            for season in selectable {
                selectedSeasons.remove(season.seasonNumber)
            }
        } else {
            for season in selectable {
                selectedSeasons.insert(season.seasonNumber)
            }
        }
    }


    private var requestButtonTitle: LocalizedStringKey {
        switch media.mediaType {
        case .movie: "catalog.button.request"
        case .tv: "catalog.button.requestSeasons"
        case .person, .unknown: "catalog.button.request"
        }
    }

    private var canSubmit: Bool {
        switch media.mediaType {
        case .movie: true
        case .tv: !selectedSeasons.isEmpty
        case .person, .unknown: false
        }
    }

    // MARK: - Derived

    private var displayTitle: String {
        movieDetail?.title ?? tvDetail?.name ?? media.displayTitle
    }

    private var displayYear: String? {
        movieDetail?.displayYear ?? tvDetail?.displayYear ?? media.displayYear
    }

    private var overview: String? {
        movieDetail?.overview ?? tvDetail?.overview ?? media.overview
    }

    private var genres: [SeerrGenre] {
        movieDetail?.genres ?? tvDetail?.genres ?? []
    }

    private var backdropPath: String? {
        movieDetail?.backdropPath ?? tvDetail?.backdropPath ?? media.backdropPath
    }

    private var mediaStatus: SeerrMediaStatus? {
        let seerr = movieDetail?.mediaInfo?.status ?? tvDetail?.mediaInfo?.status ?? media.mediaInfo?.status
        // Jellyfin ground truth: the whole title is gone, so override Seerr's stale "available" badge with .deleted.
        if (seerr == .available || seerr == .partiallyAvailable), titlePresence == .absent {
            return .deleted
        }
        return seerr
    }

    private var availableSeasons: [SeerrSeason]? {
        tvDetail?.seasons?.filter { $0.seasonNumber > 0 }
    }

    private var deviceRegion: String {
        Locale.current.region?.identifier ?? "US"
    }

    private var metadataRating: Double? {
        movieDetail?.voteAverage ?? tvDetail?.voteAverage ?? media.voteAverage
    }

    /// Runtime in minutes. Movies only; TV omits it in SP1.
    private var metadataRuntime: Int? {
        movieDetail?.runtime
    }

    private var metadataCertification: String? {
        movieDetail?.certification(region: deviceRegion)
            ?? tvDetail?.certification(region: deviceRegion)
    }

    private var castMembers: [CastMember] {
        let cast = movieDetail?.credits?.cast ?? tvDetail?.credits?.cast ?? []
        return cast.prefix(15).map { member in
            CastMember(
                id: "\(member.id)",
                name: member.name,
                role: member.character,
                imageURL: SeerrImageURL.profile(path: member.profilePath),
                personID: member.id,
                jellyfinPersonID: nil
            )
        }
    }

    /// Flatrate providers for the device region, falling back to US then the first region; empty when none.
    private var regionWatchProviders: [SeerrWatchProvider] {
        let regions = movieDetail?.watchProviders ?? tvDetail?.watchProviders ?? []
        guard !regions.isEmpty else { return [] }
        let pick = regions.first { $0.iso31661 == deviceRegion }
            ?? regions.first { $0.iso31661 == "US" }
            ?? regions.first
        return pick?.flatrate ?? []
    }

    /// Informational status for the season, or nil if untracked. Never gates requesting (status is display-only); a deleted/declined season must still be re-requestable.
    /// Layers Seerr's cached status with the Jellyfin ground-truth override: a stale "available" is downgraded to .deleted when the season's episode files are actually gone from the library.
    private func seasonStatus(_ season: SeerrSeason) -> SeerrMediaStatus? {
        let seerr = seerrSeasonStatus(season.seasonNumber)
        // Jellyfin ground truth: override Seerr's stale available/partially-available with .deleted when the show is gone entirely (titlePresence absent) or this specific season has no episode files, so the user sees it's gone (and can re-request).
        if seerr == .available || seerr == .partiallyAvailable {
            if titlePresence == .absent { return .deleted }
            if let hasFiles = jellyfinSeasonHasFiles, hasFiles[season.seasonNumber] != true {
                return .deleted
            }
        }
        return seerr
    }

    /// Seerr's own per-season status: (1) `mediaInfo.seasons`, authoritative Sonarr-scan status, the sole source of genuine availability. (2) `mediaInfo.requests[].seasons[]` for in-flight pipeline states (processing, pending approval) only from still-active requests.
    private func seerrSeasonStatus(_ n: Int) -> SeerrMediaStatus? {
        // 1. Authoritative: server-derived per-season status.
        if let mediaSeasons = tvDetail?.mediaInfo?.seasons {
            for s in mediaSeasons where s.seasonNumber == n {
                switch s.status {
                case .available: return .available
                case .partiallyAvailable: return .partiallyAvailable
                case .processing: return .processing
                case .pending: return .pending
                case .deleted: return .deleted
                case .unknown, .none: break
                }
            }
        }

        // 2. Fallback: in-flight states from still-active requests only. Jellyseerr never reverts request.seasons[].status, so a declined/failed/completed request keeps stale .pending/.processing entries; gating on request.status is required or a cancelled season stays pinned forever (overseerr#690). Availability is owned solely by path #1, so the request walk never surfaces .available.
        guard let requests = tvDetail?.mediaInfo?.requests else { return nil }
        var hasProcessing = false
        var hasPending = false
        for request in requests where request.status == .pendingApproval || request.status == .approved {
            guard let seasons = request.seasons else { continue }
            for s in seasons where s.seasonNumber == n {
                switch s.status {
                case .processing: hasProcessing = true
                case .pending: hasPending = true
                default: break
                }
            }
        }
        if hasProcessing { return .processing }
        if hasPending { return .pending }
        return nil
    }

    private func seasonStatusLabel(_ status: SeerrMediaStatus) -> LocalizedStringKey {
        switch status {
        case .available: return "catalog.seasons.alreadyAvailable"
        case .processing: return "catalog.seasons.downloading"
        case .pending: return "catalog.seasons.pendingApproval"
        case .partiallyAvailable: return "catalog.status.partiallyAvailable"
        case .deleted: return "catalog.status.removed"
        case .unknown: return "catalog.status.unknown"
        }
    }

    private func toggleSeason(_ season: SeerrSeason) {
        if selectedSeasons.contains(season.seasonNumber) {
            selectedSeasons.remove(season.seasonNumber)
        } else {
            selectedSeasons.insert(season.seasonNumber)
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Fire-and-forget (not async let): detail render must not block on best-effort Radarr/Sonarr config that only feeds optional dropdowns.
        Task { await loadServiceConfig() }
        Task { await loadRecommendations() }
        Task { await loadRatings() }

        do {
            switch media.mediaType {
            case .movie:
                movieDetail = try await dependencies.seerrMediaService.movieDetail(tmdbID: media.id)
                // Background: reconcile Seerr's cached availability against the Jellyfin library; patches the badge after first paint, never blocks.
                Task { await reconcileAvailability() }
                return
            case .tv:
                let detail = try await dependencies.seerrMediaService.tvDetail(tmdbID: media.id)
                tvDetail = detail
                Task { await reconcileAvailability() }
                // Default to the lowest real season (skip specials/season 0) synchronously so the episode block has content the instant loading ends.
                let realSeasons = (detail.seasons ?? [])
                    .filter { $0.seasonNumber > 0 }
                    .map(\.seasonNumber)
                    .sorted()
                if let first = realSeasons.first {
                    viewedSeasonNumber = first
                    // Strictly lazy (one season up front). Fanning out one tvSeasonDetail per season fired 30+ parallel HTTP/2 streams at remote Jellyseerr, saturating the pool and starving TMDB artwork loads.
                    Task { await loadSeasonEpisodes(seasonNumber: first) }
                }
                return
            case .person, .unknown:
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Cross-checks Seerr's cached availability against the Jellyfin library (the playability ground truth). Runs only when Seerr claims available/partially-available; degrades to .unknown (trust Seerr) on any lookup failure, never a false "deleted". For series it also builds the per-season episode-file map so individually deleted seasons surface even when the show is otherwise present.
    private func reconcileAvailability() async {
        guard let userID = appState.activeUser?.id else { return }
        let seerrStatus = movieDetail?.mediaInfo?.status ?? tvDetail?.mediaInfo?.status
        guard seerrStatus == .available || seerrStatus == .partiallyAvailable else { return }

        let service = dependencies.jellyfinItemService
        switch media.mediaType {
        case .movie:
            do {
                let item = try await service.findByProviderIDs(
                    userID: userID,
                    tmdbID: media.id,
                    tvdbID: nil,
                    imdbID: movieDetail?.externalIds?.imdbId,
                    includeItemTypes: [.movie]
                )
                // Present only if the matched item carries a real media source; nil match or a shell with no file counts as gone.
                titlePresence = (item?.mediaSources?.isEmpty == false) ? .present : .absent
            } catch {
                titlePresence = .unknown
            }
        case .tv:
            do {
                let series = try await service.findByProviderIDs(
                    userID: userID,
                    tmdbID: media.id,
                    tvdbID: tvDetail?.externalIds?.tvdbId,
                    imdbID: tvDetail?.externalIds?.imdbId,
                    includeItemTypes: [.series]
                )
                guard let series else {
                    // Whole series absent from the library: every Seerr-available season is gone.
                    titlePresence = .absent
                    return
                }
                titlePresence = .present
                // childCount rides on the seasons endpoint's ItemCounts field; a season Jellyfin lists with zero episode files, or doesn't list at all, was deleted.
                let seasons = try await service.getSeasons(seriesID: series.id, userID: userID).items
                var hasFiles: [Int: Bool] = [:]
                for season in seasons {
                    guard let n = season.indexNumber else { continue }
                    hasFiles[n] = (season.childCount ?? 0) > 0
                }
                jellyfinSeasonHasFiles = hasFiles
            } catch {
                titlePresence = .unknown
            }
        case .person, .unknown:
            break
        }
    }

    private func loadRecommendations() async {
        let service = dependencies.seerrMediaService
        do {
            let recs = try await service.recommendations(mediaType: media.mediaType, tmdbID: media.id)
            if !recs.isEmpty {
                recommendations = recs
                return
            }
            recommendations = try await service.similar(mediaType: media.mediaType, tmdbID: media.id)
        } catch {
            // Best-effort: leave the row absent, no banner.
        }
    }

    private func loadRatings() async {
        // Best-effort: the ratings endpoint 404s on older servers or when no
        // RT data exists, leave the badge absent in that case.
        guard let rt = try? await dependencies.seerrMediaService.ratings(
            mediaType: media.mediaType, tmdbID: media.id
        ) else { return }
        if let score = rt.criticsScore { rtCriticsScore = score }
    }

    private func loadServiceConfig() async {
        let config = dependencies.seerrServiceConfigService
        do {
            let servers: [SeerrServiceServer]
            switch media.mediaType {
            case .movie: servers = try await config.radarrServers()
            case .tv: servers = try await config.sonarrServers()
            case .person, .unknown: return
            }
            guard let chosen = servers.first(where: { $0.isDefault == true }) ?? servers.first else {
                return
            }
            let details: SeerrServiceDetails
            switch media.mediaType {
            case .movie: details = try await config.radarrDetails(serverID: chosen.id)
            case .tv: details = try await config.sonarrDetails(serverID: chosen.id)
            case .person, .unknown: return
            }
            serviceDetails = details

            // Validate the configured default against returned profiles, fall back to first. Jellyseerr's activeProfileId can be nil/0/stale; the old `?? first` only guarded nil, so a stale id shipped in the request and failed.
            let validProfileIDs = Set(details.profiles.map(\.id))
            selectedProfileID = [chosen.activeProfileId, details.server.activeProfileId]
                .compactMap { $0 }
                .first(where: validProfileIDs.contains)
                ?? details.profiles.first?.id

            let validRootFolders = Set(details.rootFolders.map(\.path))
            selectedRootFolder = [chosen.activeDirectory, details.server.activeDirectory]
                .compactMap { $0 }
                .first(where: validRootFolders.contains)
                ?? details.rootFolders.first?.path
        } catch {
            // Swallow, dropdowns simply won't appear and the request
            // will use Seerr's defaults.
        }
    }

    private func submitRequest() async {
        isSubmitting = true
        requestError = nil
        defer { isSubmitting = false }

        let seasons: [Int]? = media.mediaType == .tv ? Array(selectedSeasons) : nil

        do {
            _ = try await dependencies.seerrRequestService.createRequest(
                mediaType: media.mediaType,
                tmdbID: media.id,
                seasons: seasons,
                serverID: serviceDetails?.server.id,
                profileID: selectedProfileID,
                rootFolder: selectedRootFolder,
                languageProfileID: serviceDetails?.server.activeLanguageProfileId,
                tags: selectedTagIDs.isEmpty ? nil : Array(selectedTagIDs)
            )
            didRequest = true
            // Nudge request lists (My Requests / admin queue) to refresh; they only reload-when-empty on section switch.
            NotificationCenter.default.post(name: .seerrRequestDidSubmit, object: nil)
            // Refresh mediaInfo so chips/badges drop stale "not requested" state. NOT load(): that flips the full-screen loading state and re-runs config/recommendations.
            await refreshDetailAfterRequest()
        } catch {
            requestError = error.localizedDescription
        }
    }

    /// Light refresh after a successful request: replaces only the mediaInfo-carrying detail (badges/chips pick up pending state); tab selection and episode lists stay untouched.
    private func refreshDetailAfterRequest() async {
        do {
            switch media.mediaType {
            case .movie:
                movieDetail = try await dependencies.seerrMediaService.movieDetail(tmdbID: media.id)
            case .tv:
                tvDetail = try await dependencies.seerrMediaService.tvDetail(tmdbID: media.id)
            case .person, .unknown:
                break
            }
        } catch {
            // Badges stay stale until the next open; not worth an alert.
        }
    }
}
