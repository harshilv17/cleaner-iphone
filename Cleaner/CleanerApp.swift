import SwiftUI

@main
struct CleanerApp: App {
    @State private var library = PhotoLibraryService()
    @State private var basket = Basket()
    @State private var contacts = ContactsService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(basket)
                .environment(contacts)
                .preferredColorScheme(.dark)
                .tint(.brandAccent)
        }
    }
}
