import SwiftUI

/// Every session CSV still on the device.
///
/// The safety net for the export flow: a share sheet dismissed by accident,
/// or a phone-to-Mac transfer put off until the evening, costs nothing —
/// the files stay here until they are deliberately deleted.
struct SessionsView: View {
    @State private var sessions: [SessionFile] = []
    @State private var pendingDeletion: SessionFile?

    private let store = SessionStore.shared

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Completed walks are saved here as CSV files.")
                )
            } else {
                Section {
                    ForEach(sessions) { session in
                        row(for: session)
                    }
                } footer: {
                    Text("These files are also in the Files app under On My iPhone → WayWalk Research, and in Finder when the phone is connected to a Mac.")
                }

                if sessions.count > 1 {
                    Section {
                        ShareLink(items: sessions.map(\.url)) {
                            Label("Export all \(sessions.count) sessions", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                }
            }
        }
        .navigationTitle("Past Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDeletion {
                    store.delete(pendingDeletion)
                    reload()
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("\(pendingDeletion?.fileName ?? "") will be removed from this device. If it has not been exported yet, the data is gone.")
        }
    }

    private func row(for session: SessionFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.participantID)
                    .font(.headline)
                if let walkID = session.walkID {
                    Text(walkID.rawValue == "walkA" ? "Walk A" : "Walk B")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                Spacer()
                ShareLink(item: session.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }

            Text(session.recordedAt.map(Self.dateFormatter.string(from:)) ?? session.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(byteDescription(session.byteCount))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .swipeActions {
            Button(role: .destructive) {
                pendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func reload() {
        sessions = store.sessions()
    }
}
