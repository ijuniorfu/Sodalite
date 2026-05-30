import SwiftUI

/// "My Media" row: one tile per video library. Tapping a tile opens
/// that library in the shared FilteredGridView (the caller builds the
/// FilterDestination with the library's parentID).
struct LibraryRow: View {
    let titleKey: LocalizedStringKey
    let libraries: [JellyfinLibrary]
    let onSelect: (JellyfinLibrary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(libraries) { library in
                        LibraryTile(library: library) {
                            onSelect(library)
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 20)
            }
        }
    }
}

private struct LibraryTile: View {
    let library: JellyfinLibrary
    let action: () -> Void

    // Match the .landscape MediaCard image dimensions so My Media
    // tiles line up with the rows above them.
    private let width: CGFloat = 360
    private let height: CGFloat = 202

    var body: some View {
        FocusableCard(action: action) { isFocused in
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.16), Color(white: 0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 14) {
                    Image(systemName: symbol(for: library.libraryType))
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text(library.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                // Match the MediaCard focus stroke: concentric outer
                // border (card radius + stroke width), pushed 3pt past
                // the edge so it sits around the tile.
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isFocused)
            )
        }
    }

    private func symbol(for type: LibraryType) -> String {
        switch type {
        case .movies: "film"
        case .tvshows: "tv"
        case .homevideos: "video"
        default: "rectangle.stack"
        }
    }
}
