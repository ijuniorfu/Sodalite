import SwiftUI

extension View {
    /// Applies `transform` only when `condition` is true, otherwise returns
    /// the view unchanged. Handy for attaching a modifier (e.g. `.focused`)
    /// to a single element inside a `ForEach`.
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
