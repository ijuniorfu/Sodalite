import SwiftUI

extension View {
    /// Applies `transform` only when `condition` is true; handy for a conditional modifier (e.g. `.focused`) inside a `ForEach`.
    @ViewBuilder
    func applyIf<Transformed: View>(
        _ condition: Bool,
        transform: (Self) -> Transformed
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
