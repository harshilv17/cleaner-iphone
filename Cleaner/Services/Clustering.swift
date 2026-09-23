import Foundation

/// A photo reduced to what the grouping pass needs, so PHAsset (not Sendable) never
/// has to cross an isolation boundary. No byte size here on purpose: reading it costs
/// a resource lookup per asset, so it is only fetched for photos that end up grouped.
struct AssetRef: Sendable {
    let id: String
    let date: Date
    let modified: Date?
    let pixels: Int
    /// Favourited, or picked by hand from a burst. Can be kept, never offered for removal.
    let protected: Bool

    /// Cache key. An edit bumps the modification date, so an edited photo is
    /// re-read rather than matched on a print of what it used to look like.
    var key: String { "\(id)|\(modified?.timeIntervalSince1970 ?? 0)" }
}

/// The pure half of similar-photo grouping: which photos get compared, and how the
/// measured distances become groups. No PhotoKit or Vision, so `Checks/` runs it on a Mac.
enum Clustering {
    struct Pair: Sendable {
        let a: Int, b: Int
        let distance: Double
    }

    struct Group: Equatable {
        let keeper: Int
        let others: [Int]
    }

    /// How many later photos each one is compared against.
    static let window = 12
    /// Photos further apart than this are never compared. Similar shots are taken in
    /// one sitting, and two sunsets a year apart are not duplicates.
    static let windowSeconds: TimeInterval = 180

    /// Pairs worth measuring, from capture time alone. `refs` must be date-ordered.
    static func candidatePairs(_ refs: [AssetRef]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for i in refs.indices {
            for j in (i + 1)..<min(i + 1 + window, refs.count) {
                if refs[j].date.timeIntervalSince(refs[i].date) > windowSeconds { break }
                out.append((i, j))
            }
        }
        return out
    }

    /// Union-find over the pairs under `threshold` finds sets of related photos. It is
    /// transitive, though: a slow pan chains A~B~C where A and C look nothing alike. So
    /// each set is then split around its best photo: only members within `threshold`
    /// of that keeper join it, and the rest start over around their own best. Every
    /// photo offered for removal looks like the photo being kept, and protected photos
    /// are only ever kept.
    static func groups(
        _ refs: [AssetRef],
        pairs: [Pair],
        threshold: Double,
        isBetter: (Int, Int) -> Bool,
        distance: (Int, Int) -> Double?
    ) -> [Group] {
        var union = UnionFind(count: refs.count)
        for pair in pairs where pair.distance < threshold {
            union.union(pair.a, pair.b)
        }
        var sets = [Int: [Int]]()
        for i in refs.indices { sets[union.find(i), default: []].append(i) }

        var out: [Group] = []
        for set in sets.values where set.count > 1 {
            var remaining = set.sorted(by: isBetter)
            while let keeper = remaining.first {
                let near = remaining.dropFirst().filter { distance(keeper, $0).map { $0 < threshold } ?? false }
                let others = near.filter { !refs[$0].protected }
                // A protected photo is never an "other", so it stays free to be the
                // keeper of its own near-duplicates.
                remaining.removeAll { $0 == keeper || others.contains($0) }
                if !others.isEmpty { out.append(Group(keeper: keeper, others: others)) }
            }
        }
        return out.sorted { $0.keeper < $1.keeper }
    }
}

/// Plain union-find with path compression.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ i: Int) -> Int {
        var root = i
        while parent[root] != root { root = parent[root] }
        var walk = i
        while parent[walk] != root {
            let next = parent[walk]
            parent[walk] = root
            walk = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[rb] = ra }
    }
}
