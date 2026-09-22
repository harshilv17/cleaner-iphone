import SwiftUI

struct DuplicateContactsView: View {
    @Environment(ContactsService.self) private var contacts
    @State private var confirming: ContactCluster?

    var body: some View {
        Group {
            switch contacts.access {
            case .unknown:
                VStack(spacing: 12) {
                    Text("Let Cleaner check your contacts").font(.headline)
                    Text("It compares the entries on this iPhone to find the same person saved twice. Contacts never leave the device.")
                        .font(.footnote).multilineTextAlignment(.center)
                        .foregroundStyle(Color.brandDim)
                    Button("Continue") {
                        Task {
                            await contacts.requestAccess()
                            await contacts.scan()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(28)

            case .denied:
                ContentUnavailableView {
                    Label("Contact access is off", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Turn it on in Settings to find duplicates.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

            case .limited, .full:
                if contacts.scanning {
                    ProgressView("Comparing contacts…")
                } else if contacts.clusters.isEmpty {
                    ContentUnavailableView(
                        "No duplicates",
                        systemImage: "person.2",
                        description: Text("Every contact on this iPhone looks distinct.")
                    )
                } else {
                    list
                }
            }
        }
        .navigationTitle("Duplicate contacts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            contacts.refreshAccess()
            if contacts.access.canScan && contacts.clusters.isEmpty { await contacts.scan() }
        }
        .confirmationDialog(
            confirming.map { "Merge \($0.extras + 1) entries for \($0.name)?" } ?? "",
            isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button("Merge", role: .destructive) {
                if let cluster = confirming {
                    Task { await contacts.merge(cluster) }
                }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("Phone numbers and emails are combined onto one entry, and the extra copies are deleted. This cannot be undone from inside Cleaner.")
        }
    }

    private var list: some View {
        List(contacts.clusters) { cluster in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(cluster.name).font(.body.weight(.medium))
                    Text(cluster.detail.isEmpty ? "\(cluster.ids.count) entries" : cluster.detail)
                        .font(.caption).foregroundStyle(Color.brandDim).lineLimit(1)
                }
                Spacer()
                Text("+\(cluster.extras)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandAccent)
                Button("Merge") { confirming = cluster }
                    .buttonStyle(.bordered)
                    .font(.caption)
            }
        }
        .listStyle(.plain)
    }
}
