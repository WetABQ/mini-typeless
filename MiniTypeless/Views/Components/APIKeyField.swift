import SwiftUI

struct APIKeyField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack {
            if isRevealed {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
        }
    }
}
