import SwiftUI

/// "Where to watch" strip: streaming (flatrate) provider logos for the
/// resolved region. The caller passes the already-region-resolved
/// provider list; this view only renders. The caller guards emptiness.
struct SeerrWatchProvidersRow: View {
    var title: LocalizedStringKey = "catalog.watchProviders"
    let providers: [SeerrWatchProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(providers) { provider in
                        VStack(spacing: 6) {
                            AsyncCachedImage(url: SeerrImageURL.logo(path: provider.logoPath)) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } placeholder: {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Text(provider.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 80)
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 8)
            }
        }
    }
}
