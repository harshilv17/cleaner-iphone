import SwiftUI

/// Groups of near-identical shots. The keeper is marked and never pre-selected; the
/// rest can be taken in one tap per group, which is what the brief asks for and also
/// the only shape that makes a 40-group list usable.
struct SimilarPhotosView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket

    var body: some View {
        @Bindable var library = library
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Picker("Match", selection: $library.strictness) {
                    ForEach(Strictness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(library.scanningSimilar || library.similarUnavailable)
                Text(library.strictness.blurb)
                    .font(.caption).foregroundStyle(Color.brandDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            groups
        }
        .navigationTitle("Similar photos")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var groups: some View {
        Group {
            if library.similarUnavailable {
                ContentUnavailableView(
                    "Can't compare photos here",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Apple's image model is not working on this device (it never does in the Simulator). Cleaner will not guess, so no photo is marked as similar.")
                )
            } else if library.scanningSimilar && library.similarGroups.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing your photos on this iPhone…")
                        .font(.footnote).foregroundStyle(Color.brandDim)
                }
            } else if library.regrouping {
                ProgressView("Regrouping…").frame(maxHeight: .infinity)
            } else if library.similarGroups.isEmpty {
                ContentUnavailableView(
                    "No near-identical shots",
                    systemImage: "square.on.square",
                    description: Text(library.strictness == .loose
                        ? "Nothing in this library looks like a duplicate."
                        : "Try Loose to include shots that are similar, not near-identical.")
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
        .frame(maxHeight: .infinity)
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
