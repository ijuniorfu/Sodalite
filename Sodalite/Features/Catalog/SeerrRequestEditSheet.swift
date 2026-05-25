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
        VStack(spacing: 24) {
            Text("Edit sheet placeholder, pickers land in Task 13-15")
            Button("common.cancel") { dismiss() }
        }
        .padding(48)
        .task {
            if model == nil {
                let m = SeerrRequestEditModel(
                    request: request,
                    configService: dependencies.seerrServiceConfigService
                )
                self.model = m
                await m.bootstrap()
            }
        }
    }
}
