// Self-check for the pure half of similar-photo grouping: the time window, the
// clustering, the keeper split and favourite protection. Vision and PhotoKit are
// not involved, so it runs on the Mac:
//
//   swiftc Cleaner/Services/Clustering.swift Checks/main.swift -o /tmp/clustering && /tmp/clustering

import Foundation

let t0 = Date(timeIntervalSince1970: 1_000_000)
func ref(_ id: String, _ seconds: TimeInterval, pixels: Int = 100, protected: Bool = false) -> AssetRef {
    AssetRef(id: id, date: t0.addingTimeInterval(seconds), modified: nil, pixels: pixels, protected: protected)
}

// Window: a burst pairs up, a photo 10 minutes later pairs with nothing.
let pairs = Clustering.candidatePairs([ref("a", 0), ref("b", 2), ref("c", 4), ref("far", 600)])
assert(pairs.map { "\($0.0)-\($0.1)" } == ["0-1", "0-2", "1-2"], "window: \(pairs)")

// Window caps neighbours at `window`, even inside one second.
let burst = (0..<30).map { ref("x\($0)", 0) }
assert(Clustering.candidatePairs(burst).count == (0..<30).reduce(0) { $0 + min(Clustering.window, 29 - $1) })

// A slow pan: a~b and b~c are close, but a and c look nothing alike. Union-find
// alone would offer c for removal next to keeper a; the split must not.
let refs = [ref("a", 0, pixels: 300), ref("b", 1, pixels: 200), ref("c", 2, pixels: 100)]
let d: [Set<Int>: Double] = [[0, 1]: 0.05, [1, 2]: 0.05, [0, 2]: 0.6]
let measured = [Clustering.Pair(a: 0, b: 1, distance: 0.05), .init(a: 1, b: 2, distance: 0.05)]
func groups(_ refs: [AssetRef], _ threshold: Double) -> [Clustering.Group] {
    Clustering.groups(refs, pairs: measured, threshold: threshold,
                      isBetter: { refs[$0].protected != refs[$1].protected ? refs[$0].protected : refs[$0].pixels > refs[$1].pixels },
                      distance: { d[[$0, $1]] })
}
assert(groups(refs, 0.4) == [.init(keeper: 0, others: [1])], "chain split: \(groups(refs, 0.4))")
assert(groups(refs, 0.01).isEmpty, "threshold")
assert(groups(refs, 0.7) == [.init(keeper: 0, others: [1, 2])], "loose: \(groups(refs, 0.7))")

// Keeper: the biggest photo wins unless another is a favourite, and a favourite
// is never offered for removal.
let favB = [ref("a", 0, pixels: 300), ref("b", 1, pixels: 200, protected: true), ref("c", 2, pixels: 100)]
assert(groups(favB, 0.4) == [.init(keeper: 1, others: [0, 2])], "favourite keeps: \(groups(favB, 0.4))")
let favC = [ref("a", 0, pixels: 300), ref("b", 1, pixels: 200), ref("c", 2, pixels: 100, protected: true)]
assert(groups(favC, 0.7) == [.init(keeper: 2, others: [0, 1])], "favourite keeps: \(groups(favC, 0.7))")
let favAB = [ref("a", 0, pixels: 300, protected: true), ref("b", 1, pixels: 200, protected: true), ref("c", 2, pixels: 100)]
// Two favourites: a keeps b, but b still anchors its own near-duplicate c.
assert(groups(favAB, 0.4) == [.init(keeper: 1, others: [2])], "two favourites: \(groups(favAB, 0.4))")

print("clustering ok")
