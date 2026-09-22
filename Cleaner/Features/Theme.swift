import SwiftUI

extension Color {
    static let brandAccent = Color(red: 0.18, green: 0.83, blue: 0.75)
    static let brandCard = Color(white: 0.09)
    static let brandCardEdge = Color(white: 0.20)
    static let brandDim = Color(white: 0.62)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.brandCard, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.brandCardEdge, lineWidth: 1))
    }
}
