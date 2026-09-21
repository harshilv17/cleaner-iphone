import Foundation

/// One thing the app is willing to remove, whatever kind of thing it is.
///
/// Every scanner produces these and the review screen consumes them, so there is a
/// single delete path in the app rather than one per category.
struct Candidate: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case screenshot, largeVideo, similarPhoto, duplicateContact
    }

    /// `PHAsset.localIdentifier`, or the contact identifier.
    let id: String
    let kind: Kind
    let bytes: Int64
    let subtitle: String
    /// Similar photos arrive in groups; everything else is its own group.
    var groupID: String?
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
