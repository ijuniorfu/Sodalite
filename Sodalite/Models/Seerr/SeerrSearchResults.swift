import Foundation

/// A person hit from `/api/v1/search`. Deliberately not a `SeerrMedia`: a person carried through the
/// media path ends up in CatalogDetailView, which would fetch `/movie/{id}` with a person id.
/// Bare camelCase only, the client decodes with `.convertFromSnakeCase`.
struct SeerrPersonSearchResult: Decodable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let profilePath: String?
    /// TMDB's best-known credits, mapped by Jellyseerr into the same shape as a search result.
    let knownFor: [SeerrMedia]?

    /// The two best-known titles, shown under the name in the search row. Two people of the same
    /// name are common in TMDB, and this is what tells them apart.
    var knownForSummary: String? {
        let titles = (knownFor ?? [])
            .map(\.displayTitle)
            .filter { !$0.isEmpty }
            .prefix(2)
        return titles.isEmpty ? nil : titles.joined(separator: ", ")
    }

    init(id: Int, name: String, profilePath: String? = nil, knownFor: [SeerrMedia]? = nil) {
        self.id = id
        self.name = name
        self.profilePath = profilePath
        self.knownFor = knownFor
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, profilePath, knownFor
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
        // Credits are decoration under the name, so a malformed one costs the summary, not the person.
        knownFor = (try? container.decodeIfPresent([SeerrMedia].self, forKey: .knownFor)) ?? nil
    }
}

/// `/api/v1/search`, whose `results` mix movies, series, people and collections. The entries are
/// sorted into typed lists here so no caller has to branch on `mediaType` after the fact; anything
/// Sodalite has no destination for (collections, unknown types, malformed entries) is dropped.
struct SeerrSearchResults: Decodable, Sendable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let media: [SeerrMedia]
    let people: [SeerrPersonSearchResult]

    init(
        page: Int = 1,
        totalPages: Int = 1,
        totalResults: Int = 0,
        media: [SeerrMedia] = [],
        people: [SeerrPersonSearchResult] = []
    ) {
        self.page = page
        self.totalPages = totalPages
        self.totalResults = totalResults
        self.media = media
        self.people = people
    }

    private enum CodingKeys: String, CodingKey {
        case page, totalPages, totalResults, results
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages) ?? 1
        totalResults = try container.decodeIfPresent(Int.self, forKey: .totalResults) ?? 0

        let entries = try container.decodeIfPresent([Entry].self, forKey: .results) ?? []
        media = entries.compactMap(\.media)
        people = entries.compactMap(\.person)
    }

    /// One `results` element. Decoding never throws past this point: a single bad entry must cost
    /// that entry, not the whole search.
    private enum Entry: Decodable {
        case media(SeerrMedia)
        case person(SeerrPersonSearchResult)
        case unusable

        var media: SeerrMedia? {
            if case .media(let media) = self { return media }
            return nil
        }

        var person: SeerrPersonSearchResult? {
            if case .person(let person) = self { return person }
            return nil
        }

        private enum TypeKey: String, CodingKey {
            case mediaType
        }

        init(from decoder: any Decoder) throws {
            let type = try? decoder.container(keyedBy: TypeKey.self)
                .decodeIfPresent(SeerrMediaType.self, forKey: .mediaType)
            switch type {
            case .movie, .tv:
                self = (try? SeerrMedia(from: decoder)).map(Entry.media) ?? .unusable
            case .person:
                self = (try? SeerrPersonSearchResult(from: decoder)).map(Entry.person) ?? .unusable
            default:
                self = .unusable
            }
        }
    }
}
