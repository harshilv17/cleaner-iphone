import Foundation

/// One thing the app is willing to remove, whatever kind of thing it is.
///
/// Every photo scanner produces these and the review screen consumes them, so there
/// is a single delete path in the app rather than one per category. Contacts merge
/// from their own screen instead: a merge is not a delete, and iOS offers no undo.
struct Candidate: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case screenshot, largeVideo, similarPhoto
    }

    /// `PHAsset.localIdentifier`.
    let id: String
    let kind: Kind
    let bytes: Int64
    let subtitle: String
}

enum Category: String, CaseIterable, Identifiable, Sendable {
    case screenshots, largeVideos, similarPhotos, duplicateContacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .largeVideos: "Large videos"
        case .similarPhotos: "Similar photos"
        case .duplicateContacts: "Duplicate contacts"
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .largeVideos: "film.stack"
        case .similarPhotos: "square.on.square"
        case .duplicateContacts: "person.2"
        }
    }

    var blurb: String {
        switch self {
        case .screenshots: "Every screenshot in one place."
        case .largeVideos: "Biggest videos first, with a preview."
        case .similarPhotos: "Near-identical shots, best one kept."
        case .duplicateContacts: "Entries that look like the same person."
        }
    }
}
