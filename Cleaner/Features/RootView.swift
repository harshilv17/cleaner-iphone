import SwiftUI

struct RootView: View {
    @Environment(PhotoLibraryService.self) private var library
    @Environment(Basket.self) private var basket
    @Environment(ContactsService.self) private var contacts
    @State private var reviewing = false

    var body: some View {
        NavigationStack {
            DashboardView()
                .navigationTitle("Cleaner")
                .safeAreaInset(edge: .bottom) { tray }
        }
        .task {
            library.refreshAccess()
            contacts.refreshAccess()
            if contacts.access.canScan { await contacts.scan() }
            if library.access.canScan { await library.scan() }
        }
        .sheet(isPresented: $reviewing) { ReviewView() }
    }

    /// The only way to a deletion, and it stays hidden until the user turns cleaning
    /// on in the dashboard.
    @ViewBuilder private var tray: some View {
        if !basket.isEmpty {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(basket.count) selected").font(.subheadline.weight(.semibold))
                    Text(Fmt.bytes(basket.bytes)).font(.caption).foregroundStyle(Color.brandDim)
                }
                Spacer()
                Button("Clear") { basket.clear() }
                    .buttonStyle(.bordered)
                if basket.cleaningEnabled {
                    Button("Review") { reviewing = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
    }
}
