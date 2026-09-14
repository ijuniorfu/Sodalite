import SwiftUI

/// "Where to watch" strip of flatrate provider logos; caller passes the already-region-resolved list and guards emptiness, this view only renders.
struct SeerrWatchProvidersRow: View {
    var title: LocalizedStringKey = "catalog.watchProviders"
    let providers: [SeerrWatchProvider]

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.shellPaysLeadingInset) private var shellPaysLeading
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    private var leadingInset: CGFloat { metrics.rowLeading(shellPaysLeading: shellPaysLeading) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.leading, leadingInset)
                .padding(.trailing, metrics.rowInset)

            RowScrollView(leading: leadingInset, trailing: metrics.rowInset, vertical: 8) {
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
            }
            .focusSectionCompat()
        }
    }
}
