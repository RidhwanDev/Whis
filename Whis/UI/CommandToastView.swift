import SwiftUI

struct CommandToastView: View {
    let toast: CommandToastData

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .red : .green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text("\"\(toast.phrase)\"")
                    .font(.headline)
                    .lineLimit(1)
                Text(toast.action)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(toast.isError ? Color.red.opacity(0.35) : Color.green.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
        .padding(.horizontal)
    }
}

extension View {
    func commandToast(_ toast: CommandToastData?) -> some View {
        overlay(alignment: .top) {
            if let toast {
                CommandToastView(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: toast?.id)
    }
}
