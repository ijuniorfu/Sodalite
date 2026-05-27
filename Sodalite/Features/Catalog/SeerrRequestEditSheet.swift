import SwiftUI

@MainActor
@Observable
final class SeerrRequestEditModel {
    var serverID: Int?
    var profileID: Int?
    var rootFolder: String?
    var selectedSeasons: Set<Int> = []
    var servers: [SeerrServiceServer] = []
    var profiles: [SeerrQualityProfile] = []
    var rootFolders: [SeerrRootFolder] = []
    var isLoading: Bool = true
    var loadError: String?
    var isSaving: Bool = false

    private let request: SeerrRequest
    private let configService: SeerrServiceConfigServiceProtocol

    init(request: SeerrRequest, configService: SeerrServiceConfigServiceProtocol) {
        self.request = request
        self.configService = configService
        self.serverID = request.media?.serviceId
        if let seasons = request.seasons {
            self.selectedSeasons = Set(seasons.map(\.seasonNumber))
        }
    }

    func bootstrap() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            if request.type == .movie {
                servers = try await configService.radarrServers()
            } else {
                servers = try await configService.sonarrServers()
            }
            if let activeID = serverID ?? servers.first(where: { $0.isDefault == true })?.id ?? servers.first?.id {
                serverID = activeID
                try await loadDetails(forServerID: activeID)
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func selectServer(_ id: Int) async {
        serverID = id
        profileID = nil
        rootFolder = nil
        do {
            try await loadDetails(forServerID: id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadDetails(forServerID id: Int) async throws {
        let details: SeerrServiceDetails = request.type == .movie
            ? try await configService.radarrDetails(serverID: id)
            : try await configService.sonarrDetails(serverID: id)
        profiles = details.profiles
        rootFolders = details.rootFolders
        if profileID == nil { profileID = details.profiles.first?.id }
        if rootFolder == nil { rootFolder = details.rootFolders.first?.path }
    }

    /// Build a partial body containing only fields that differ from
    /// the original request. Avoids sending unchanged values back to
    /// Jellyseerr (defensive against server-side validation that
    /// might reject a no-op edit).
    func buildUpdateBody() -> SeerrRequestUpdateBody {
        let originalSeasons = Set((request.seasons ?? []).map(\.seasonNumber))
        let newSeasons: [Int]? = (request.type == .tv && selectedSeasons != originalSeasons)
            ? Array(selectedSeasons).sorted()
            : nil
        return SeerrRequestUpdateBody(
            serverId: serverID != request.media?.serviceId ? serverID : nil,
            profileId: profileID,
            rootFolder: rootFolder,
            languageProfileId: nil,
            seasons: newSeasons,
            userId: nil
        )
    }
}

struct SeerrRequestEditSheet: View {
    let request: SeerrRequest
    @Bindable var viewModel: CatalogViewModel
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var model: SeerrRequestEditModel?

    var body: some View {
        Group {
            if let model = model {
                sheetBody(model: model)
            } else {
                ProgressView()
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
        // .task must live on the outer Group, not on the ProgressView branch.
        // Assigning self.model triggers a re-render that unmounts the ProgressView,
        // which would cancel the still-running bootstrap() URLSession call if the
        // task were attached to it. The Group stays mounted across the conditional
        // swap, so bootstrap() always runs to completion.
        .task {
            guard model == nil else { return }
            let m = SeerrRequestEditModel(
                request: request,
                configService: dependencies.seerrServiceConfigService
            )
            self.model = m
            await m.bootstrap()
        }
    }

    @ViewBuilder
    private func sheetBody(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("catalog.allRequests.edit.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(viewModel.title(for: request) ?? "#\(request.id)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = model.loadError {
                errorView(message: error, retry: { Task { await model.bootstrap() } })
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                pickerSection(model: model)
            }

            Spacer()

            footer(model: model)
        }
        .padding(48)
        .frame(maxWidth: 800)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private func pickerSection(model: SeerrRequestEditModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            serverPicker(model: model)
            profilePicker(model: model)
            rootFolderPicker(model: model)
            if request.type == .tv {
                seasonsPicker(model: model)
            }
        }
    }

    private func profilePicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.profile",
            options: model.profiles,
            selected: model.profiles.first(where: { $0.id == model.profileID }),
            label: { $0.name },
            onSelect: { profile in model.profileID = profile.id }
        )
    }

    private func rootFolderPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: "catalog.allRequests.edit.rootFolder",
            options: model.rootFolders,
            selected: model.rootFolders.first(where: { $0.path == model.rootFolder }),
            label: { $0.path },
            onSelect: { folder in model.rootFolder = folder.path }
        )
    }

    @ViewBuilder
    private func seasonsPicker(model: SeerrRequestEditModel) -> some View {
        if let seasons = request.seasons, !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("catalog.allRequests.edit.seasons")
                    .font(.body)
                    .fontWeight(.medium)
                    .padding(.horizontal, 24)
                ForEach(seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber })) { season in
                    SeasonCheckboxRow(
                        seasonNumber: season.seasonNumber,
                        isOn: model.selectedSeasons.contains(season.seasonNumber),
                        toggle: {
                            if model.selectedSeasons.contains(season.seasonNumber) {
                                model.selectedSeasons.remove(season.seasonNumber)
                            } else {
                                model.selectedSeasons.insert(season.seasonNumber)
                            }
                        }
                    )
                }
            }
        } else {
            EmptyView()
        }
    }

    private func serverPicker(model: SeerrRequestEditModel) -> some View {
        EditPickerRow(
            title: request.type == .movie
                ? "catalog.allRequests.edit.server.radarr"
                : "catalog.allRequests.edit.server.sonarr",
            options: model.servers,
            selected: model.servers.first(where: { $0.id == model.serverID }),
            label: { $0.name },
            onSelect: { server in
                Task { await model.selectServer(server.id) }
            }
        )
    }

    private func footer(model: SeerrRequestEditModel) -> some View {
        HStack(spacing: 24) {
            GlassActionButton(
                title: "common.cancel",
                systemImage: "xmark",
                action: { dismiss() }
            )
            .disabled(model.isSaving)

            GlassActionButton(
                title: "catalog.allRequests.edit.save",
                systemImage: "checkmark",
                isProminent: true,
                isLoading: model.isSaving,
                action: { Task { await save(model: model) } }
            )
            .disabled(model.isSaving || model.serverID == nil || isSeasonSelectionInvalid(model: model))
        }
    }

    /// TV requests must have at least one season selected; otherwise
    /// Jellyseerr's update endpoint accepts `seasons: []` and clears
    /// the request to zero requested seasons, which is a destructive
    /// foot-gun the spec does not intend. Movie requests are always
    /// valid (selectedSeasons is empty by design).
    private func isSeasonSelectionInvalid(model: SeerrRequestEditModel) -> Bool {
        guard request.type == .tv else { return false }
        guard request.seasons?.isEmpty == false else { return false }
        return model.selectedSeasons.isEmpty
    }

    private func errorView(message: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("catalog.allRequests.edit.serverLoadError")
                .font(.body)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            GlassActionButton(
                title: "home.retry",
                systemImage: "arrow.clockwise",
                action: retry
            )
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func save(model: SeerrRequestEditModel) async {
        model.isSaving = true
        defer { model.isSaving = false }
        let body = model.buildUpdateBody()
        let updated = await viewModel.updateRequest(request, body: body)
        if updated != nil {
            dismiss()
        }
    }
}

// MARK: - SeasonCheckboxRow

/// Focusable checkbox row for one season. Follows the
/// feedback_sodalite_ui_focus_and_tint rules: `.focusable(true)`
/// not Button, `.tint` stroke, `.tint`-tinted fill when focused.
private struct SeasonCheckboxRow: View {
    let seasonNumber: Int
    let isOn: Bool
    let toggle: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.5)))
            Text(String(
                format: String(localized: "catalog.allRequests.edit.season.format", defaultValue: "Season %d"),
                seasonNumber
            ))
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(focused
                      ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) { toggle() }
        .animation(.easeInOut(duration: 0.15), value: focused)
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

// MARK: - EditPickerRow

/// Generic single-select picker row for the Edit sheet. Same focus
/// conventions as ValuePickerRow: left/right cycles, .tint stroke,
/// .tint-tinted fill when focused.
private struct EditPickerRow<Option: Identifiable & Equatable>: View {
    let title: LocalizedStringKey
    let options: [Option]
    let selected: Option?
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white : Color.secondary)
                    .opacity(canMoveBackward ? 1 : 0.25)
                Text(selected.map(label) ?? String(localized: "catalog.allRequests.edit.loading", defaultValue: "Loading..."))
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(minWidth: 180, alignment: .center)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white : Color.secondary)
                    .opacity(canMoveForward ? 1 : 0.25)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(focused
                      ? AnyShapeStyle(TintShapeStyle.tint.opacity(0.18))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .focusable(!options.isEmpty)
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left:  advance(by: -1)
            case .right: advance(by: 1)
            default: break
            }
        }
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private var currentIndex: Int? { options.firstIndex(where: { $0 == selected }) }
    private var canMoveBackward: Bool { (currentIndex ?? 0) > 0 }
    private var canMoveForward: Bool { (currentIndex ?? -1) < options.count - 1 }

    private func advance(by step: Int) {
        guard let idx = currentIndex else { return }
        let new = max(0, min(options.count - 1, idx + step))
        if new != idx { onSelect(options[new]) }
    }
}
