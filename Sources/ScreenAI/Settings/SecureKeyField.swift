import SwiftUI

/// API Key 输入框：暗文显示；按住右侧眼睛图标时显示明文，松开恢复。
struct SecureKeyField: View {
    let title: String
    @Binding var value: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                TextField(title, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .opacity(revealed ? 1 : 0)
                SecureField(title, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .opacity(revealed ? 0 : 1)
            }
            Image(systemName: revealed ? "eye.fill" : "eye")
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in revealed = true }
                    .onEnded { _ in revealed = false })
                .help("按住显示明文")
        }
    }
}
