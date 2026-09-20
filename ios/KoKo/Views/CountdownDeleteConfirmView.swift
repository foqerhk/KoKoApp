import SwiftUI

/// Shared swipe-delete confirmation with a short countdown before the destructive action enables.
struct CountdownDeleteConfirmView: View {
    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var secondsLeft = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer(minLength: 8)

                Button {
                    guard secondsLeft == 0 else { return }
                    onConfirm()
                } label: {
                    Text(secondsLeft > 0
                         ? String(format: String(localized: "Delete in %llds"), Int64(secondsLeft))
                         : confirmLabel)
                        .font(.headline)
                        .foregroundStyle(secondsLeft > 0 ? Color(red: 0.55, green: 0.08, blue: 0.10) : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(secondsLeft > 0
                                      ? Color(red: 1.0, green: 0.78, blue: 0.78)
                                      : Color(red: 0.92, green: 0.22, blue: 0.22))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onCancel) {
                    Text(String(localized: "Cancel"))
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                secondsLeft = 3
                while secondsLeft > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    secondsLeft -= 1
                }
            }
        }
        .presentationDetents([.medium])
    }
}
