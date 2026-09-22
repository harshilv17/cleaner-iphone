import SwiftUI

/// Groups of near-identical shots. The keeper is marked and never pre-selected; the
/// rest can be taken in one tap per group, which is what the brief asks for and also
/// the only shape that makes a 40-group list usable.
struct SimilarPhotosView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket

    var body: some View {
        Group {
            if library.scanningSimilar && library.similarGroups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing your photos on this iPhone…")
                        .font(.footnote).foregroundStyle(Color.brandDim)
                }
            } else if library.similarGroups.isEmpty {
                ContentUnavailableView(
                    "No near-identical shots",
                    systemImage: "square.on.square",
                    description: Text("Nothing in this library looks like a duplicate.")
                )
            } else {
                List {
                    ForEach(library.similarGroups) { group in
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    keeper(group)
                                    ForEach(group.others) { item in
                                        tile(item)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            HStack {
                                Text("\(group.others.count + 1) shots · \(Fmt.bytes(group.reclaimable)) extra")
                                Spacer()
                                Button(selected(group) ? "Deselect" : "Select \(group.others.count)") {
                                    selected(group)
                                        ? basket.remove(group.others.map(\.id))
                                        : basket.add(group.others)
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func selected(_ group: SimilarGroup) -> Bool {
        !group.others.isEmpty && group.others.allSatisfy { basket.contains($0.id) }
    }

    private func keeper(_ group: SimilarGroup) -> some View {
        VStack(spacing: 4) {
            AssetThumbnail(id: group.keeper, side: 96)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.brandAccent, lineWidth: 2))
            Label("Best", systemImage: "star.fill")
                .font(.caption2).foregroundStyle(Color.brandAccent)
        }
    }

    private func tile(_ item: Candidate) -> some View {
        let picked = basket.contains(item.id)
        return Button {
            basket.toggle(item)
        } label: {
            VStack(spacing: 4) {
                AssetThumbnail(id: item.id, side: 96)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked ? Color.brandAccent : .white.opacity(0.8))
                            .padding(5)
                    }
                    .opacity(picked ? 0.55 : 1)
                Text(Fmt.bytes(item.bytes)).font(.caption2).foregroundStyle(Color.brandDim)
            }
        }
        .buttonStyle(.plain)
    }
}
