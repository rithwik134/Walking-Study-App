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
        Group {
            if sessions.isEmpty {
                // Outside the List deliberately: nested in a list row this
                // renders squeezed into a single inset cell instead of
                // filling the screen.
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "tray",
                    description: Text("Completed walks are saved here as CSV files.")
                )
            } else {
                list
            }
        }
        .navigationTitle("Past Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if sessions.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(items: sessions.map(\.url)) {
                        Label("Export all", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }
        }
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

    private var list: some View {
        List {
            Section {
                ForEach(sessions) { session in
                    row(for: session)
                }
            } footer: {
                Text("Also in the Files app under On My iPhone → WayWalk Research, and in Finder when the phone is connected to a Mac.")
            }
        }
    }

    private func row(for session: SessionFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: modeIcon(session.mode))
                .font(.system(size: 17))
                .foregroundStyle(session.mode == .study ? walkTint(session.walkID) : modeTint(session.mode))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.participantID)
                        .font(.headline)

                    if let walkID = session.walkID {
                        badge(walkLabel(walkID), tint: walkTint(walkID))
                    }
                    if let marker = session.mode.fileNameMarker {
                        badge(marker, tint: modeTint(session.mode))
                    }
                }

                Text(secondaryLine(for: session))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            ShareLink(item: session.url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func secondaryLine(for session: SessionFile) -> String {
        let date = session.recordedAt.map(Self.dateFormatter.string(from:)) ?? session.fileName
        return "\(date) · \(byteDescription(session.byteCount))"
    }

    private func modeIcon(_ mode: SessionMode) -> String {
        switch mode {
        case .study: return "figure.walk"
        case .test: return "testtube.2"
        case .manual: return "hand.tap.fill"
        }
    }

    /// Matches the tints used on the Home screen for each mode.
    private func modeTint(_ mode: SessionMode) -> Color {
        switch mode {
        case .study: return .secondary
        case .test: return .orange
        case .manual: return .indigo
        }
    }

    /// Matches the colours the routes are drawn in on the maps, so a session
    /// is recognisable at a glance.
    private func walkTint(_ walkID: WalkID?) -> Color {
        switch walkID {
        case .walkA: return .orange
        case .walkB: return .purple
        case nil: return .secondary
        }
    }

    private func walkLabel(_ walkID: WalkID) -> String {
        switch walkID {
        case .walkA: return "Walk A"
        case .walkB: return "Walk B"
        }
    }

    private func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func reload() {
        sessions = store.sessions()
    }
}
