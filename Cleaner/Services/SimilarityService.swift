import Photos
import UIKit
import Vision

/// A photo reduced to what the grouping pass needs, so PHAsset (not Sendable) never
/// has to cross an isolation boundary.
struct AssetRef: Sendable {
    let id: String
    let date: Date
    let bytes: Int64
    let pixels: Int
}

/// One cluster of near-identical shots, with the keeper already chosen.
struct SimilarGroup: Identifiable, Sendable {
    let id: String
    let keeper: String
    let others: [Candidate]

    var reclaimable: Int64 { others.reduce(0) { $0 + $1.bytes } }
}

/// Finding near-identical photos is the expensive half of this app, and the naive
/// version is quadratic: 20k photos is 200M comparisons, which never finishes on a
/// phone. Three things keep it linear-ish:
///
///  1. An exact-duplicate pass on metadata alone — same pixel size, same second,
///     same byte count — which costs nothing because no pixels are read.
///  2. A sliding window. Near-identical shots are bursts, seconds apart, so each
///     photo is only compared with its neighbours in time rather than the whole
///     library. O(n · k) instead of O(n²).
///  3. Feature prints computed from small thumbnails, cached by identifier, and
///     never fetched over the network.
enum SimilarityService {
    /// Distance below which two feature prints are treated as the same shot. Vision
    /// distances are not absolute truth; this wants calibrating against a real
    /// library, which is what `threshold` being a constant here is admitting.
    static let threshold: Double = 0.3
    /// How many later photos each one is compared against.
    static let window = 12
    /// Photos closer together than this are candidates; further apart, skip.
    static let windowSeconds: TimeInterval = 180

    static func scan(
        refs: [AssetRef],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> [SimilarGroup] {
        guard refs.count > 1 else { return [] }
        let ordered = refs.sorted { $0.date < $1.date }

        var union = UnionFind(count: ordered.count)
        var prints = [Int: FeaturePrintObservation]()

        for i in 0..<ordered.count {
            if i % 20 == 0 { progress(i, ordered.count) }
            for j in (i + 1)..<min(i + 1 + window, ordered.count) {
                let a = ordered[i], b = ordered[j]
                if b.date.timeIntervalSince(a.date) > windowSeconds { break }
                if union.find(i) == union.find(j) { continue }

                // Free pass first: identical geometry and byte count is a copy.
                if a.pixels == b.pixels, a.bytes == b.bytes, a.bytes > 0 {
                    union.union(i, j)
                    continue
                }
                guard let pa = await featurePrint(for: a.id, cache: &prints, index: i),
                      let pb = await featurePrint(for: b.id, cache: &prints, index: j)
                else { continue }
                if let d = try? pa.distance(to: pb), d < threshold {
                    union.union(i, j)
                }
            }
        }

        progress(ordered.count, ordered.count)

        // Turn the clusters into groups, dropping the singletons.
        var buckets = [Int: [AssetRef]]()
        for (index, ref) in ordered.enumerated() {
            buckets[union.find(index), default: []].append(ref)
        }

        var groups: [SimilarGroup] = []
        for (_, members) in buckets where members.count > 1 {
            let keeper = await bestShot(among: members)
            let others = members.filter { $0.id != keeper }.map {
                Candidate(
                    id: $0.id,
                    kind: .similarPhoto,
                    bytes: $0.bytes,
                    subtitle: $0.date.formatted(date: .abbreviated, time: .shortened),
                    groupID: keeper
                )
            }
            groups.append(SimilarGroup(id: keeper, keeper: keeper, others: others))
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Apple already solved "which of these is the good one": the aesthetics request
    /// returns a score and a flag for utility shots (receipts, screenshots of text).
    /// Falls back to the biggest file, which is usually the least compressed.
    private static func bestShot(among members: [AssetRef]) async -> String {
        var best = members.max(by: { $0.bytes < $1.bytes })?.id ?? members[0].id
        var bestScore = -Float.greatestFiniteMagnitude
        for member in members {
            guard let image = await thumbnail(for: member.id, side: 512),
                  let cg = image.cgImage else { continue }
            let request = CalculateImageAestheticsScoresRequest()
            guard let observation = try? await request.perform(on: cg) else { continue }
            let score = observation.isUtility ? observation.overallScore - 1 : observation.overallScore
            if score > bestScore {
                bestScore = score
                best = member.id
            }
        }
        return best
    }

    private static func featurePrint(
        for id: String,
        cache: inout [Int: FeaturePrintObservation],
        index: Int
    ) async -> FeaturePrintObservation? {
        if let hit = cache[index] { return hit }
        guard let image = await thumbnail(for: id, side: 320), let cg = image.cgImage else {
            return nil
        }
        let request = GenerateImageFeaturePrintRequest()
        guard let observation = try? await request.perform(on: cg) else { return nil }
        cache[index] = observation
        return observation
    }

    private static func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        await PhotoLibraryService.thumbnail(for: id, side: side)
    }
}

/// Plain union-find. Grouping is transitive — if A matches B and B matches C, all
/// three belong together even when A and C were never compared.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ i: Int) -> Int {
        var root = i
        while parent[root] != root { root = parent[root] }
        var walk = i
        while parent[walk] != root {           // path compression
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
