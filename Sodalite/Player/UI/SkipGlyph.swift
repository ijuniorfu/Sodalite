import Foundation

/// The SF Symbol a jump of a given length draws itself with, shared by the tvOS seek readout and the
/// touch HUD so the two cannot drift apart (Sodalite#144, where the HUD still said 10 while the
/// remote jumped 30).
///
/// SF Symbols ships `goforward`/`gobackward` numbered at these steps only, and both call sites
/// compose the name from a number, so anything else would render as a blank box. The unnumbered
/// glyph is the fallback rather than a crash: a length that is not offered in Settings today could
/// still arrive from a future transport.
enum SkipGlyph {
    static let numbered: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]

    /// `direction` negative is back, anything else forward. `seconds` is a magnitude.
    static func name(seconds: Int, direction: Int) -> String {
        let base = direction < 0 ? "gobackward" : "goforward"
        return numbered.contains(seconds) ? "\(base).\(seconds)" : base
    }
}
