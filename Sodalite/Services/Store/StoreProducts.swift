import Foundation

/// IAP product identifiers; must match App Store Connect for `de.superuser404.Sodalite`. Tips are consumables (buy repeatedly); Supporter Pack is non-consumable (one-time, restored across devices).
enum StoreProducts {

    // MARK: - Tip Jar (consumables)

    static let tipCoffee = "de.superuser404.Sodalite.tip.coffee"
    static let tipBeer   = "de.superuser404.Sodalite.tip.beer"
    static let tipPizza  = "de.superuser404.Sodalite.tip.pizza"

    // MARK: - Supporter Pack (non-consumable)

    static let supporterPack = "de.superuser404.Sodalite.supporter.pack"

    // MARK: - Groups

    static let allTipIDs: [String] = [tipCoffee, tipBeer, tipPizza]
    static let allNonConsumableIDs: [String] = [supporterPack]
    static let allProductIDs: [String] = allTipIDs + allNonConsumableIDs

    static func isTipJar(_ id: String) -> Bool {
        allTipIDs.contains(id)
    }

    static func isSupporterPack(_ id: String) -> Bool {
        id == supporterPack
    }
}
