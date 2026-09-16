import SwiftUI

/// How much of a waypoint's script to show.
enum PromptDisplay: Equatable {
    /// Both conditions side by side — for the checking screens, where
    /// comparing the two scripts is the entire point.
    case both
    /// Only the script that will actually be spoken — for the active walk,
    /// where showing the other condition would just be misleading.
    case only(InformationLevel)
}

/// Bottom card describing one waypoint: where it is, how big its trigger
/// radius is, and what will be said when it fires.
///
/// Shared by the route overview, waypoint test mode and the active walk so
/// all three describe a waypoint identically.
struct WaypointPreviewCard: View {
    let waypoint: Waypoint
    let index: Int
    let total: Int
    let display: PromptDisplay
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch display {
            case .both:
                bothConditions
            case .only(let level):
                singleCondition(level)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8, y: 2)
        .padding(.horizontal)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Waypoint \(index + 1)")
                .font(.headline)
            Text("of \(total)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close waypoint preview")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
        }
    }

    // MARK: - Prompt rendering

    private var bothConditions: some View {
        VStack(alignment: .leading, spacing: 14) {
            promptBlock(
                title: InformationLevel.navigationOnly.rawValue,
                tint: .blue
            ) {
                Text(waypoint.navigationPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            promptBlock(
                title: InformationLevel.navigationPlusContext.rawValue,
                tint: .purple
            ) {
                Text(waypoint.contextualPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func singleCondition(_ level: InformationLevel) -> some View {
        promptBlock(
            title: level.rawValue,
            tint: level == .navigationOnly ? .blue : .purple
        ) {
            if waypoint.isOnRoute(for: level) {
                Text(waypoint.script(for: level).trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                offRouteText(for: level)
            }
        }
    }

    /// A waypoint with no script for a condition is not on that condition's
    /// route — the Gordon Square branches are built this way — and is skipped
    /// outright rather than fired silently. Saying so beats an empty block,
    /// which reads as missing data on the one screen a researcher uses to
    /// check the branch before a run.
    private func offRouteText(for level: InformationLevel) -> some View {
        Text("Not on this route — skipped under \(level.rawValue).")
            .italic()
            .foregroundStyle(.secondary)
    }

    private func promptBlock<Content: View>(
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(tint)
            content()
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func words(in text: String) -> [Substring] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
    }

    /// Compares words ignoring case and trailing punctuation, so a word that
    /// ends the navigation sentence still matches the same word continuing
    /// mid-sentence in the contextual one.
    private static func normalised(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
