import SwiftUI

struct DestinationPickerSheet: View {
    let destinations: [DestinationSummary]
    let itemCount: Int
    let onSelect: (DestinationSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        "No SMB Shares",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Add a share in Settings before sending these items.")
                    )
                } else {
                    List(destinations) { destination in
                        Button {
                            dismiss()
                            onSelect(destination)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "externaldrive.fill")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 36, height: 36)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(destination.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(destination.displayPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Send \(itemCount) Item\(itemCount == 1 ? "" : "s") To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
