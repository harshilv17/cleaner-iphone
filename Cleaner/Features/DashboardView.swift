import Photos
import PhotosUI
import SwiftUI

struct DashboardView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket
    @Environment(ContactsService.self) private var contacts
    private var similarFraction: Double {
        library.similarTotal > 0 ? Double(library.similarDone) / Double(library.similarTotal) : 0
    }
    @State private var storage = DeviceStorage.read()

    private var found: Int64 {
        library.screenshots.reduce(0) { $0 + $1.bytes }
            + library.largeVideos.reduce(0) { $0 + $1.bytes }
            + library.similarGroups.reduce(0) { $0 + $1.reclaimable }
    }

    var body: some View {
        @Bindable var basket = basket
        ScrollView {
            VStack(spacing: 14) {
                storageCard

                if library.pendingPurge > 0 { purgeCard }

                switch library.access {
                case .unknown: permissionCard
                case .denied: deniedCard
                case .limited, .full:
                    if library.access == .limited { limitedNote }
                    foundCard
                    ForEach(Category.allCases) { category in
                        NavigationLink {
                            if category == .similarPhotos {
                                SimilarPhotosView()
                            } else if category == .duplicateContacts {
                                DuplicateContactsView()
                            } else {
                                CategoryListView(category: category)
                            }
                        } label: {
                            categoryRow(category)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("Allow cleaning", isOn: $basket.cleaningEnabled)
                    .tint(.brandAccent)
                    .padding(.horizontal, 4)
                Text(basket.isEmpty
                     ? "Off by default. Cleaner reports what it finds and nothing can be deleted until you switch this on."
                     : "\(basket.count) items selected, \(Fmt.bytes(basket.bytes)). Switch this on to review and remove them.")
                    .font(.caption)
                    .foregroundStyle(basket.isEmpty ? Color.brandDim : Color.brandAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .refreshable { await library.scan() }
    }

    private var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("iPhone storage", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandDim)
                Text(Fmt.bytes(storage.available)).font(.system(size: 34, weight: .semibold))
                Text("free of \(Fmt.bytes(storage.total)) · approximate")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                ProgressView(value: storage.fraction).tint(.brandAccent)
            }
        }
    }

    private var foundCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Could be freed", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandDim)
                if library.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Fmt.bytes(found))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                }
                Text("Across screenshots, large videos and near-identical shots on this iPhone.")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                if library.scanningSimilar {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: similarFraction).tint(.brandAccent)
                        Text("Reading photo \(Fmt.count(library.similarDone)) of \(Fmt.count(library.similarTotal))")
                            .font(.caption2).foregroundStyle(Color.brandDim)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var purgeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Waiting in Recently Deleted", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandDim)
                Text(Fmt.bytes(library.pendingPurge))
                    .font(.system(size: 26, weight: .semibold))
                Text("iOS keeps deleted photos for 30 days, so this space is not back yet. Empty Recently Deleted to get it.")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                Button("Open Photos") { library.openRecentlyDeleted() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var permissionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Let Cleaner look at your photos").font(.headline)
                Text("It reads the library on this iPhone to find screenshots, large videos and near-identical shots. Nothing is uploaded, and nothing is deleted without you choosing it.")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                Button("Continue") {
                    Task {
                        await library.requestAccess()
                        await contacts.requestAccess()
                        if contacts.access.canScan { await contacts.scan() }
                        if library.access.canScan { await library.scan() }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var deniedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Photo access is off").font(.headline)
                Text("Cleaner can still show your storage, but it cannot find anything to free until it can read the library.")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Limited access is a working state, not an error: scan what was shared and
    /// offer the picker rather than nagging.
    private var limitedNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Looking at selected photos only").font(.subheadline.weight(.semibold))
                Text("You shared part of your library. Cleaner works with what it can see.")
                    .font(.footnote).foregroundStyle(Color.brandDim)
                Button("Select more photos") {
                    guard let scene = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene }).first,
                        let root = scene.keyWindow?.rootViewController else { return }
                    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { _ in
                        Task { await library.scan() }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func categoryRow(_ category: Category) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: category.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.brandAccent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.body.weight(.medium))
                    Text(category.blurb).font(.caption).foregroundStyle(Color.brandDim)
                }
                Spacer()
                HStack(spacing: -10) {
                    ForEach(preview(category), id: \.self) { id in
                        AssetThumbnail(id: id, side: 34)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brandCard, lineWidth: 2))
                    }
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(summary(category)).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Color.brandDim)
                }
            }
        }
    }

    /// Up to three real thumbnails per row.
    private func preview(_ category: Category) -> [String] {
        switch category {
        case .screenshots: library.screenshots.prefix(3).map(\.id)
        case .largeVideos: library.largeVideos.prefix(3).map(\.id)
        case .similarPhotos: library.similarGroups.prefix(3).map(\.keeper)
        case .duplicateContacts: []
        }
    }

    private func summary(_ category: Category) -> String {
        if library.scanning { return "…" }
        switch category {
        case .screenshots:
            let n = library.screenshots.reduce(0) { $0 + $1.bytes }
            return n > 0 ? Fmt.bytes(n) : "None"
        case .largeVideos:
            let n = library.largeVideos.reduce(0) { $0 + $1.bytes }
            return n > 0 ? Fmt.bytes(n) : "None"
        case .similarPhotos:
            if library.scanningSimilar { return "Scanning…" }
            if library.similarUnavailable { return "Unavailable" }
            let n = library.similarGroups.reduce(0) { $0 + $1.reclaimable }
            return n > 0 ? Fmt.bytes(n) : "None"
        case .duplicateContacts:
            return contacts.clusters.isEmpty ? "Check" : "\(contacts.clusters.count) sets"
        }
    }
}
