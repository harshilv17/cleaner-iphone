import Foundation
import Photos
import UIKit
import Vision

/// One cluster of near-identical shots, with the keeper already chosen.
struct SimilarGroup: Identifiable, Sendable {
    let id: String
    let keeper: String
    let others: [Candidate]

    var reclaimable: Int64 { others.reduce(0) { $0 + $1.bytes } }
}

/// How close two shots must be to count as the same, as a distance between 64 px
/// feature prints. Measured across crops, pans, rotation, blur, exposure and
/// re-encoding of real photos (`Checks/distances.swift` reproduces it):
///
///   re-saved, resized, re-compressed, exposure edits   ≤ 0.05
///   small crop or pan, slight shake                    ≤ 0.07
///   3° rotation, 20% crop, 10% pan, mirrored           ≤ 0.17
///   out of focus                                        ≤ 0.33
///   different photos, even of the same kind of scene   ≥ 0.59
enum Strictness: String, CaseIterable, Identifiable, Sendable {
    case strict, balanced, loose

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var threshold: Double {
        switch self {
        case .strict: 0.08
        case .balanced: 0.4
        case .loose: 0.5
        }
    }

    var blurb: String {
        switch self {
        case .strict: "Near-exact copies: the same shot re-saved, resized or lightly edited."
        case .balanced: "The same moment: bursts and retakes, including the blurry frame."
        case .loose: "A bit similar: the same scene, reframed or a moment later."
        }
    }
}

/// Every distance the scan measured. Grouping is a function of this plus a threshold,
/// so changing strictness regroups without reading a single photo again.
struct SimilarityIndex: Sendable {
    /// Date-ordered; pairs and prints index into this.
    let refs: [AssetRef]
    let pairs: [Clustering.Pair]
    /// Prints of photos in at least one pair, the only photos grouping can touch.
    let prints: [Int: FeaturePrintObservation]

    static let empty = SimilarityIndex(refs: [], pairs: [], prints: [:])
}

/// Finding similar photos, on the device, fast enough for a 20k library:
///
///  1. Candidates come from capture time (`Clustering.candidatePairs`): similar shots
///     are taken seconds apart, so each photo is compared only with its neighbours.
///     O(n · k) instead of O(n²), and photos with no neighbour are never read.
///  2. Each candidate gets a Vision feature print from a 64 px thumbnail, in parallel,
///     cached on disk, so a rescan only pays for new or edited photos.
///  3. Groups are split around their best photo, and the best photo is chosen by
///     protection, resolution, then Vision's aesthetics score.
///
/// Perceptual hashes (dHash and friends) were measured and rejected: a 5–10% camera
/// pan moves 7–36 of 64 bits, overlapping unrelated photos at 21–34. They find
/// copies and nothing "a bit similar", which the prints handle as well.
enum SimilarityService {
    /// Measured: at 320 px the print mostly tracks sharpness, and a slightly blurred
    /// copy scores further from its original (0.40) than a different waterfall does
    /// (0.41). At 64 px the same shot stays under 0.33 however blurred, and different
    /// photos stay above 0.59. Bump the `VisionCache` file when changing this.
    static let printSide: CGFloat = 64
    /// The keeper choice is about sharpness and exposure, so it gets a real image.
    static let scoreSide: CGFloat = 320

    /// `nil` when Vision cannot tell images apart on this device (in the Simulator it
    /// returns one vector for everything). Better no groups than every photo in one.
    static func index(
        _ refs: [AssetRef],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> SimilarityIndex? {
        guard await visionWorks() else { return nil }
        let refs = refs.sorted { $0.date < $1.date }
        await VisionCache.shared.retain(Set(refs.map(\.key)))

        let candidates = Clustering.candidatePairs(refs)
        let needed = Array(Set(candidates.flatMap { [$0.0, $0.1] })).sorted()
        let prints = await concurrentMap(needed, progress: progress) { i in
            await featurePrint(refs[i])
        }

        let pairs = candidates.compactMap { i, j -> Clustering.Pair? in
            guard let a = prints[i], let b = prints[j],
                  let d = try? a.distance(to: b),
                  d < Strictness.loose.threshold
            else { return nil }
            return .init(a: i, b: j, distance: d)
        }
        let paired = Set(pairs.flatMap { [$0.a, $0.b] })
        await VisionCache.shared.save()
        return SimilarityIndex(refs: refs, pairs: pairs, prints: prints.filter { paired.contains($0.key) })
    }

    static func groups(in index: SimilarityIndex, threshold: Double) async -> [SimilarGroup] {
        let refs = index.refs
        // Only photos with a pair under the threshold can end up grouped; score just those.
        let members = Array(Set(index.pairs.filter { $0.distance < threshold }.flatMap { [$0.a, $0.b] })).sorted()
        guard !members.isEmpty else { return [] }

        let bytes = PhotoLibraryService.bytes(for: members.map { refs[$0].id })
        let scores = await concurrentMap(members) { i in await aestheticsScore(refs[i]) }
        await VisionCache.shared.save()

        // Protected photos first; then the higher resolution, so a shrunken copy is
        // never the one kept; then the better-looking shot; then the bigger file.
        func isBetter(_ a: Int, _ b: Int) -> Bool {
            let (ra, rb) = (refs[a], refs[b])
            if ra.protected != rb.protected { return ra.protected }
            if ra.pixels != rb.pixels { return ra.pixels > rb.pixels }
            let (sa, sb) = (scores[a] ?? -.infinity, scores[b] ?? -.infinity)
            if sa != sb { return sa > sb }
            return bytes[ra.id, default: 0] > bytes[rb.id, default: 0]
        }

        let groups = Clustering.groups(refs, pairs: index.pairs, threshold: threshold, isBetter: isBetter) { a, b in
            guard let pa = index.prints[a], let pb = index.prints[b] else { return nil }
            return try? pa.distance(to: pb)
        }
        return groups.map { group in
            let keeper = refs[group.keeper].id
            return SimilarGroup(id: keeper, keeper: keeper, others: group.others.map { i in
                Candidate(
                    id: refs[i].id,
                    kind: .similarPhoto,
                    bytes: bytes[refs[i].id, default: 0],
                    subtitle: refs[i].date.formatted(date: .abbreviated, time: .shortened)
                )
            })
        }
        .sorted { $0.reclaimable > $1.reclaimable }
    }

    // MARK: - Vision

    private static func featurePrint(_ ref: AssetRef) async -> FeaturePrintObservation? {
        if let hit = await VisionCache.shared.featurePrint(ref.key) { return hit }
        guard let image = await PhotoLibraryService.thumbnail(for: ref.id, side: printSide),
              let cg = image.cgImage,
              let observation = try? await GenerateImageFeaturePrintRequest()
                .perform(on: cg, orientation: image.cgOrientation)
        else { return nil }
        await VisionCache.shared.store(observation, for: ref.key)
        return observation
    }

    /// Apple already solved "which of these is the good one": the aesthetics request
    /// scores sharpness and exposure, and flags utility shots (receipts, documents),
    /// which are pushed down so a real photo wins over a snap of a page.
    private static func aestheticsScore(_ ref: AssetRef) async -> Float? {
        if let hit = await VisionCache.shared.score(ref.key) { return hit }
        guard let image = await PhotoLibraryService.thumbnail(for: ref.id, side: scoreSide),
              let cg = image.cgImage,
              let observation = try? await CalculateImageAestheticsScoresRequest()
                .perform(on: cg, orientation: image.cgOrientation)
        else { return nil }
        let score = observation.isUtility ? observation.overallScore - 1 : observation.overallScore
        await VisionCache.shared.store(score, for: ref.key)
        return score
    }

    /// Two images that look nothing alike must come out far apart before any photo is
    /// grouped. A working model scores these 1.39. The Simulator's cannot run at all,
    /// or, forced onto the CPU, returns the same vector for every image.
    private static func visionWorks() async -> Bool {
        guard let plain = canary(striped: false), let striped = canary(striped: true),
              let a = try? await GenerateImageFeaturePrintRequest().perform(on: plain),
              let b = try? await GenerateImageFeaturePrintRequest().perform(on: striped),
              let d = try? a.distance(to: b)
        else { return false }
        return d > Strictness.loose.threshold
    }

    private static func canary(striped: Bool) -> CGImage? {
        let side = Int(printSide)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if striped {
            context.setFillColor(gray: 0, alpha: 1)
            for y in stride(from: 0, to: side, by: 8) {
                context.fill(CGRect(x: 0, y: y, width: side, height: 4))
            }
        }
        return context.makeImage()
    }

    /// Runs `work` over `items` with at most one task per core in flight, so a 20k-photo
    /// library does not queue 20k thumbnail requests at once.
    private static func concurrentMap<T: Sendable>(
        _ items: [Int],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        _ work: @escaping @Sendable (Int) async -> T?
    ) async -> [Int: T] {
        await withTaskGroup(of: (Int, T?).self) { group in
            var pending = items.makeIterator()
            for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
                guard let i = pending.next() else { break }
                group.addTask { (i, await work(i)) }
            }
            var out = [Int: T]()
            var done = 0
            for await (i, value) in group {
                out[i] = value
                done += 1
                if done % 20 == 0 { progress(done, items.count) }
                if let next = pending.next() { group.addTask { (next, await work(next)) } }
            }
            progress(items.count, items.count)
            return out
        }
    }
}

extension UIImage {
    /// PhotoKit hands back camera photos with the pixels as the sensor stored them and
    /// the rotation in `imageOrientation`. Vision has to be told, or a portrait photo
    /// and its re-saved (already rotated) copy look 90° apart.
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// Feature prints and aesthetics scores, kept on disk between launches. A cold scan
/// pays for Vision once; every later scan only reads photos that are new or edited.
///
/// ponytail: one binary plist rewritten whole on save — ~3 KB per photo, so about
/// 60 MB at 20k photos. Move to SwiftData or a SQLite blob table if that write shows up.
actor VisionCache {
    static let shared = VisionCache()

    private struct Store: Codable {
        var prints: [String: FeaturePrintObservation] = [:]
        var scores: [String: Float] = [:]
    }

    private var store: Store
    private var dirty = false
    /// The version is the print recipe: v2 is 64 px. A print made another way is not
    /// comparable, so a new recipe gets a new file.
    private let url = URL.cachesDirectory.appending(path: "vision-cache-v2.plist")

    private init() {
        store = (try? Data(contentsOf: url))
            .flatMap { try? PropertyListDecoder().decode(Store.self, from: $0) } ?? Store()
    }

    func featurePrint(_ key: String) -> FeaturePrintObservation? { store.prints[key] }
    func score(_ key: String) -> Float? { store.scores[key] }

    func store(_ print: FeaturePrintObservation, for key: String) {
        store.prints[key] = print
        dirty = true
    }

    func store(_ score: Float, for key: String) {
        store.scores[key] = score
        dirty = true
    }

    /// Drops entries for photos that were deleted or edited since the last scan.
    func retain(_ live: Set<String>) {
        let before = store.prints.count + store.scores.count
        store.prints = store.prints.filter { live.contains($0.key) }
        store.scores = store.scores.filter { live.contains($0.key) }
        if store.prints.count + store.scores.count != before { dirty = true }
    }

    func save() {
        guard dirty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: url, options: .atomic)
        dirty = false
    }
}
