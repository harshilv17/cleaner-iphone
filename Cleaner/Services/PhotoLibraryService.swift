import OSLog
import Photos
import SwiftUI

let log = Logger(subsystem: "cleaner", category: "scan")

@MainActor
@Observable
final class PhotoLibraryService {
    enum Access: Equatable {
        case unknown, denied, limited, full

        var canScan: Bool { self == .limited || self == .full }
    }

    private(set) var access: Access = .unknown
    private(set) var screenshots: [Candidate] = []
    private(set) var largeVideos: [Candidate] = []
    private(set) var similarGroups: [SimilarGroup] = []
    private(set) var scanning = false
    /// Similar photos take far longer than the other two, so the UI reports that
    /// pass separately instead of holding everything behind one spinner.
    private(set) var scanningSimilar = false
    /// How far the similar-photo pass has got, so a minutes-long scan on a real
    /// library shows movement rather than one motionless word.
    private(set) var similarDone = 0
    private(set) var similarTotal = 0
    /// Set after a delete so the UI can be honest about Recently Deleted.
    private(set) var pendingPurge: Int64 = 0

    func refreshAccess() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
    }

    private static func map(_ s: PHAuthorizationStatus) -> Access {
        switch s {
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        default: .unknown
        }
    }

    func scan() async {
        guard access.canScan, !scanning else { return }
        scanning = true
        // The cheap fetches land first so the dashboard has numbers immediately.
        screenshots = Self.fetchScreenshots()
        largeVideos = Self.fetchLargeVideos()
        scanning = false

        guard !scanningSimilar else { return }
        scanningSimilar = true
        defer { scanningSimilar = false }
        let refs = Self.fetchImageRefs()
        similarTotal = refs.count
        similarDone = 0
        log.notice("access=\(String(describing: self.access)) screenshots=\(self.screenshots.count) videos=\(self.largeVideos.count) imageRefs=\(refs.count) firstBytes=\(refs.first?.bytes ?? -1)")
        similarGroups = await SimilarityService.scan(refs: refs) { done, total in
            Task { @MainActor in
                self.similarDone = done
                self.similarTotal = total
            }
        }
        log.notice("similarGroups=\(self.similarGroups.count) reclaimable=\(self.similarGroups.reduce(0) { $0 + $1.reclaimable })")
    }

    /// Everything the grouping pass needs, without carrying PHAsset across actors.
    private static func fetchImageRefs() -> [AssetRef] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var out: [AssetRef] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            out.append(AssetRef(
                id: asset.localIdentifier,
                date: asset.creationDate ?? .distantPast,
                bytes: assetBytes(asset),
                pixels: asset.pixelWidth * asset.pixelHeight
            ))
        }
        return out
    }

    // MARK: - Fetching

    /// The system already maintains a Screenshots album, so this is a fetch rather
    /// than a detector.
    private static func fetchScreenshots() -> [Candidate] {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil
        )
        guard let album = albums.firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var out: [Candidate] = []
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            out.append(Candidate(
                id: asset.localIdentifier,
                kind: .screenshot,
                bytes: assetBytes(asset),
                subtitle: asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
            ))
        }
        return out
    }

    private static func fetchLargeVideos() -> [Candidate] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "duration", ascending: false)]
        var out: [Candidate] = []
        PHAsset.fetchAssets(with: .video, options: options).enumerateObjects { asset, _, _ in
            let bytes = assetBytes(asset)
            let mins = Int(asset.duration) / 60
            let secs = Int(asset.duration) % 60
            out.append(Candidate(
                id: asset.localIdentifier,
                kind: .largeVideo,
                bytes: bytes,
                subtitle: String(format: "%d:%02d", mins, secs)
            ))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// PHAsset exposes no public size. `fileSize` on the resource is the approach in
    /// universal use, but it is an undocumented key, so a nil falls back to an
    /// estimate from the pixel count rather than reporting zero and hiding the asset.
    ///
    /// ponytail: metadata only, no file is read — fast enough to run on the main
    /// actor. If a 50k-video library ever hitches here, move it to a background
    /// context keyed by localIdentifier.
    static func assetBytes(_ asset: PHAsset) -> Int64 {
        for resource in PHAssetResource.assetResources(for: asset) {
            if let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
                return size
            }
        }
        return Int64(asset.pixelWidth * asset.pixelHeight) / 4
    }

    /// Fetch a small rendition of an asset.
    ///
    /// The first attempt stays strictly local. On an iCloud-optimised library that
    /// fails with `networkAccessRequired` (3303) and, with no retry, every thumbnail
    /// in the app is an empty grey box and the similarity pass finds nothing — which
    /// is exactly what a "messy" real library looks like. So the retry allows the
    /// network, but only ever for these small renditions: `fastFormat` at a few
    /// hundred pixels never pulls the full-size original down.
    nonisolated static func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let target = CGSize(width: side, height: side)
        if let local = await request(asset, target, network: false) { return local }
        return await request(asset, target, network: true)
    }

    private nonisolated static func request(
        _ asset: PHAsset, _ target: CGSize, network: Bool
    ) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFill, options: options
            ) { image, info in
                // fastFormat can still deliver a degraded pass first; take the first
                // usable result and ignore the rest, because resuming twice traps.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, image != nil || !degraded else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    static func assets(for ids: [String]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var out: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    // MARK: - Deleting

    /// Every deletion in the app funnels through here, in ONE `performChanges` call.
    ///
    /// iOS puts up its own "Delete N Photos?" sheet and reports success only if the
    /// user confirmed — batching means one sheet rather than one per photo. The
    /// assets then sit in Recently Deleted for 30 days, so the space does not come
    /// back yet; `pendingPurge` is what the UI uses to say so instead of claiming a
    /// win the storage number will not show.
    @discardableResult
    func deleteAssets(ids: [String], bytes: Int64) async -> Bool {
        let assets = Self.assets(for: ids)
        guard !assets.isEmpty else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            return false   // the user cancelled the system sheet
        }
        pendingPurge += bytes
        screenshots.removeAll { ids.contains($0.id) }
        largeVideos.removeAll { ids.contains($0.id) }
        similarGroups = similarGroups.compactMap { group in
            let kept = group.others.filter { !ids.contains($0.id) }
            return kept.isEmpty ? nil : SimilarGroup(id: group.id, keeper: group.keeper, others: kept)
        }
        return true
    }

    func openRecentlyDeleted() {
        // The Photos app's own URL scheme; falls back to just opening Photos.
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}
