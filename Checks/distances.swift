// Calibration for similar photos: runs the app's recipe (a Vision feature print of a
// 64 px thumbnail, then `Clustering.groups`) over a folder of images on the Mac and
// prints every distance plus the groups each strictness tier would form. Vision runs
// the same model here as on the iPhone; the Simulator's cannot run it at all.
//
//   swiftc -O -target arm64-apple-macos26.0 Cleaner/Services/Clustering.swift \
//     Checks/distances.swift -o /tmp/distances && /tmp/distances ~/some/photos
//
// Every image counts as taken at the same moment, so the folder is one burst.
// Keep `side` and `tiers` in step with `SimilarityService.printSide` and `Strictness`.

import CoreImage
import Foundation
import Vision

@main
enum Distances {
    static let side: CGFloat = 64
    static let tiers: [(String, Double)] = [("strict", 0.08), ("balanced", 0.4), ("loose", 0.5)]

    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let context = CIContext()

        var names: [String] = [], prints: [FeaturePrintObservation] = [], refs: [AssetRef] = []
        for file in files {
            guard let image = CIImage(contentsOf: file, options: [.applyOrientationProperty: true]) else { continue }
            let scale = side / min(image.extent.width, image.extent.height)
            let small = image.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale])
            guard let cg = context.createCGImage(small, from: small.extent.integral) else { continue }
            prints.append(try await GenerateImageFeaturePrintRequest().perform(on: cg))
            names.append(file.deletingPathExtension().lastPathComponent)
            refs.append(AssetRef(id: file.lastPathComponent, date: .distantPast, modified: nil,
                                 pixels: Int(image.extent.width * image.extent.height), protected: false))
        }

        func distance(_ a: Int, _ b: Int) -> Double { (try? prints[a].distance(to: prints[b])) ?? .infinity }
        let width = max(8, (names.map(\.count).max() ?? 0) + 2)
        print("".padding(toLength: width, withPad: " ", startingAt: 0)
              + names.indices.map { String(format: "%6d", $0) }.joined())
        for i in names.indices {
            print("\(i) \(names[i])".padding(toLength: width, withPad: " ", startingAt: 0)
                  + names.indices.map { String(format: "%6.3f", distance(i, $0)) }.joined())
        }

        let pairs = Clustering.candidatePairs(refs).map { Clustering.Pair(a: $0.0, b: $0.1, distance: distance($0.0, $0.1)) }
        for (tier, threshold) in tiers {
            let groups = Clustering.groups(refs, pairs: pairs, threshold: threshold,
                                           isBetter: { refs[$0].pixels > refs[$1].pixels }, distance: distance)
            print("\n\(tier) (< \(threshold)): " + (groups.isEmpty ? "no groups" : ""))
            for g in groups { print("  keep \(names[g.keeper]), offer " + g.others.map { names[$0] }.joined(separator: ", ")) }
        }
    }
}
