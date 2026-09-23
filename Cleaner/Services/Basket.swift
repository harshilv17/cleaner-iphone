import SwiftUI

/// What the user has ticked, across every category. Nothing is deleted anywhere
/// else in the app — the review screen is the only exit from here.
@MainActor
@Observable
final class Basket {
    private(set) var items: [String: Candidate] = [:]

    /// Analyze-first: the app reports by default and only reveals the Clean button
    /// when this is switched on, so a scan can never end in an accidental delete.
    var cleaningEnabled = false

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var bytes: Int64 { items.values.reduce(0) { $0 + $1.bytes } }

    func contains(_ id: String) -> Bool { items[id] != nil }

    func toggle(_ c: Candidate) {
        if items[c.id] == nil { items[c.id] = c } else { items[c.id] = nil }
    }

    func add(_ cs: [Candidate]) { for c in cs { items[c.id] = c } }
    func remove(_ ids: [String]) { for id in ids { items[id] = nil } }
    func clear() { items.removeAll() }
}
