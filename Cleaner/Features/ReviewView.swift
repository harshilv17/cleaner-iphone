import SwiftUI

/// The single gate in front of every deletion. Nothing leaves the device and nothing
/// is removed until the button here is pressed — and then iOS puts up its own
/// confirmation on top of this one.
struct ReviewView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var cancelled = false

    private var photoItems: [Candidate] {
        basket.items.values
            .filter { $0.kind != .duplicateContact }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Fmt.bytes(basket.bytes))
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.brandAccent)
                        Text("\(basket.count) items. iOS will ask you to confirm, then keep them in Recently Deleted for 30 days — the space comes back when you empty that.")
                            .font(.footnote)
                            .foregroundStyle(Color.brandDim)
                    }
                    .padding(.vertical, 4)
                }

                Section("Will be removed") {
                    ForEach(photoItems) { item in
                        HStack(spacing: 12) {
                            AssetThumbnail(id: item.id, side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.bytes(item.bytes)).font(.subheadline)
                                Text(item.subtitle).font(.caption).foregroundStyle(Color.brandDim)
                            }
                            Spacer()
                            Button {
                                basket.toggle(item)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.brandDim)
                        }
                    }
                }

                if cancelled {
                    Text("Nothing was deleted — the confirmation was dismissed.")
                        .font(.footnote)
                        .foregroundStyle(Color.brandDim)
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "Deleting…" : "Delete") { Task { await confirm() } }
                        .disabled(working || basket.isEmpty)
                }
            }
        }
    }

    private func confirm() async {
        working = true
        defer { working = false }
        let ids = photoItems.map(\.id)
        let bytes = photoItems.reduce(0) { $0 + $1.bytes }
        let ok = await library.deleteAssets(ids: ids, bytes: bytes)
        if ok {
            basket.remove(ids)
            dismiss()
        } else {
            cancelled = true
        }
    }
}
