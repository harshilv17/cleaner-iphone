import AVFoundation
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
    /// Set while a strictness change is regrouping; only new keepers cost Vision work.
    private(set) var regrouping = false
    /// Vision failed its self-test (always, in the Simulator), so nothing is grouped
    /// and the UI says why rather than claiming there are no duplicates.
    private(set) var similarUnavailable = false
    /// Set after a delete so the UI can be honest about Recently Deleted.
    private(set) var pendingPurge: Int64 = 0

    var strictness: Strictness = .balanced {
        didSet { if strictness != oldValue { Task { await regroup() } } }
    }
    private var index = SimilarityIndex.empty

    /// Videos under this are not worth a row: a phone full of 5-second clips is not
    /// where the space went.
    nonisolated static let largeVideoBytes: Int64 = 20_000_000

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

    /// Safe to call again (pull to refresh, limited picker): the Vision cache makes a
    /// rescan cost only what changed since the last one.
    func scan() async {
        guard access.canScan, !scanning else { return }
        scanning = true
        // The cheap fetches land first so the dashboard has numbers immediately.
        // Off the main actor: the size lookup is per asset and adds up.
        (screenshots, largeVideos) = await Task.detached {
            (Self.fetchScreenshots(), Self.fetchLargeVideos())
        }.value
        scanning = false

        guard !scanningSimilar else { return }
        scanningSimilar = true
        defer { scanningSimilar = false }
        let refs = await Task.detached { Self.fetchImageRefs() }.value
        similarTotal = refs.count
        similarDone = 0
        log.notice("access=\(String(describing: self.access)) screenshots=\(self.screenshots.count) videos=\(self.largeVideos.count) imageRefs=\(refs.count)")
        let built = await SimilarityService.index(refs) { done, total in
            Task { @MainActor in
                self.similarDone = done
                self.similarTotal = total
            }
        }
        similarUnavailable = built == nil
        index = built ?? .empty
        for pair in index.pairs {
            // Calibration data for the strictness thresholds, on device:
            // `log stream --level debug --predicate 'subsystem == "cleaner"'`.
            log.debug("distance \(pair.distance, format: .fixed(precision: 3)) \(self.index.refs[pair.a].id) \(self.index.refs[pair.b].id)")
        }
        await regroup()
        log.notice("pairs=\(self.index.pairs.count) similarGroups=\(self.similarGroups.count) reclaimable=\(self.similarGroups.reduce(0) { $0 + $1.reclaimable })")
    }

    private func regroup() async {
        let wanted = strictness
        regrouping = true
        let groups = await SimilarityService.groups(in: index, threshold: wanted.threshold)
        // A later strictness change may have finished first; the newest one wins.
        guard wanted == strictness else { return }
        similarGroups = groups
        regrouping = false
    }

    /// Everything the grouping pass needs, without carrying PHAsset across actors.
    /// Hidden burst frames are included, since a burst is the classic pile of
    /// near-identical shots. Screenshots are left out: they have their own category,
    /// and counting them twice would inflate "could be freed".
    private nonisolated static func fetchImageRefs() -> [AssetRef] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeAllBurstAssets = true
        var out: [AssetRef] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            out.append(AssetRef(
                id: asset.localIdentifier,
                date: asset.creationDate ?? .distantPast,
                modified: asset.modificationDate,
                pixels: asset.pixelWidth * asset.pixelHeight,
                protected: asset.isFavorite || asset.burstSelectionTypes.contains(.userPick)
            ))
        }
        return out
    }

    // MARK: - Fetching

    /// The system already maintains a Screenshots album, so this is a fetch rather
    /// than a detector.
    private nonisolated static func fetchScreenshots() -> [Candidate] {
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

    private nonisolated static func fetchLargeVideos() -> [Candidate] {
        var out: [Candidate] = []
        PHAsset.fetchAssets(with: .video, options: nil).enumerateObjects { asset, _, _ in
            let bytes = assetBytes(asset)
            guard bytes >= largeVideoBytes else { return }
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
    /// Metadata only, no file is read — but it is a lookup per asset, so callers run
    /// it off the main actor.
    nonisolated static func assetBytes(_ asset: PHAsset) -> Int64 {
        for resource in PHAssetResource.assetResources(for: asset) {
            if let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
                return size
            }
        }
        return Int64(asset.pixelWidth * asset.pixelHeight) / 4
    }

    /// A rendition exactly `side` pixels on its short edge.
    ///
    /// `highQualityFormat`, because `fastFormat` only hands back a thumbnail that is
    /// already cached and fails with `networkAccessRequired` (3303) when there is
    /// none, network allowed or not: a fresh import, an iCloud-optimised library.
    /// That left every thumbnail a grey box and the similarity pass with no input.
    /// The network is allowed for this small rendition only, never the original.
    nonisolated static func thumbnail(for id: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill, options: options
            ) { image, _ in
                // One call is documented for highQualityFormat; resuming twice traps.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated static func bytes(for ids: [String]) -> [String: Int64] {
        var out = [String: Int64]()
        for asset in assets(for: ids) { out[asset.localIdentifier] = assetBytes(asset) }
        return out
    }

    /// A playable file for the preview. `.original` hands back a plain file even for
    /// slo-mo, which would otherwise arrive as a composition with no URL.
    ///
    /// ponytail: an iCloud-only video downloads in full before it plays. Switch to
    /// `requestPlayerItem` for streaming if that wait shows up on device.
    nonisolated static func videoURL(for id: String) async -> URL? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in
                continuation.resume(returning: (av as? AVURLAsset)?.url)
            }
        }
    }

    nonisolated static func assets(for ids: [String]) -> [PHAsset] {
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
        // Keep the index in step, or the next strictness change would regroup
        // photos that no longer exist.
        let gone = Set(ids)
        index = SimilarityIndex(
            refs: index.refs,
            pairs: index.pairs.filter { !gone.contains(index.refs[$0.a].id) && !gone.contains(index.refs[$0.b].id) },
            prints: index.prints
        )
        return true
    }

    func openRecentlyDeleted() {
        // The Photos app's own URL scheme; falls back to just opening Photos.
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }
}
