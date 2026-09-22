import SwiftUI

struct CategoryListView: View {
    let category: Category

    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket

    private var items: [Candidate] {
        switch category {
        case .screenshots: library.screenshots
        case .largeVideos: library.largeVideos
        case .similarPhotos, .duplicateContacts: []
        }
    }

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView(
                    comingSoon ? "Not built yet" : "Nothing found",
                    systemImage: category.symbol,
                    description: Text(comingSoon
                        ? "Similar photos and duplicate contacts are next."
                        : "There is nothing in this category on this iPhone.")
                )
            } else {
                Section {
                    ForEach(items) { item in
                        row(item)
                    }
                } header: {
                    HStack {
                        Text("\(Fmt.count(items.count)) items · \(Fmt.bytes(items.reduce(0) { $0 + $1.bytes }))")
                        Spacer()
                        Button(allSelected ? "Deselect all" : "Select all") {
                            allSelected ? basket.remove(items.map(\.id)) : basket.add(items)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var comingSoon: Bool {
        category == .similarPhotos || category == .duplicateContacts
    }

    private var allSelected: Bool {
        !items.isEmpty && items.allSatisfy { basket.contains($0.id) }
    }

    private func row(_ item: Candidate) -> some View {
        let picked = basket.contains(item.id)
        return Button {
            basket.toggle(item)
        } label: {
            HStack(spacing: 12) {
                AssetThumbnail(id: item.id, side: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Fmt.bytes(item.bytes)).font(.subheadline.weight(.medium))
                    Text(item.subtitle).font(.caption).foregroundStyle(Color.brandDim)
                }
                Spacer()
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.brandAccent : Color.brandCardEdge)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(picked ? Color.brandAccent.opacity(0.12) : Color.clear)
    }
}
