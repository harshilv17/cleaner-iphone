import Photos
import SwiftUI

/// Thumbnails only, and never from iCloud: `isNetworkAccessAllowed = false` keeps a
/// library scan off the network entirely, which is both faster and not rude on a
/// metered connection.
struct AssetThumbnail: View {
    let id: String
    var side: CGFloat = 92

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.brandCardEdge.opacity(0.4))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 10))
        .task(id: id) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        image = await PhotoLibraryService.thumbnail(for: id, side: side * UIScreen.main.scale)
    }
}
