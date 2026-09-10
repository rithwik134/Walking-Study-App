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
                contextualText
            }
        }
    }

    /// The contextual script restates the navigation instruction verbatim at
    /// its start — the two are alternatives, never concatenated. Dimming that
    /// shared opening makes the *added* context legible instead of looking
    /// like the text was accidentally duplicated between the two blocks.
    @ViewBuilder
    private var contextualText: some View {
        let contextual = (waypoint.contextualPrompt ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if contextual.isEmpty {
            offRouteText(for: .navigationPlusContext)
        } else if let (shared, added) = Self.splitSharedPrefix(
            navigation: waypoint.navigationPrompt,
            contextual: contextual
        ), !added.isEmpty {
            Text(shared).foregroundStyle(.secondary)
                + Text(" ")
                + Text(added).foregroundStyle(.primary)
        } else {
            Text(contextual)
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

    /// Fewest shared words worth dimming. Two is enough to be a real opening
    /// ("Continue straight", "Turn right") and short enough that the common
    /// two-word instructions in the route data still split.
    private static let minimumSharedWords = 2

    /// Splits a contextual script into the opening it shares with the
    /// navigation prompt and the part that differs, so the card can dim the
    /// repetition and show the added context at full strength.
    ///
    /// This compares word by word rather than checking for a whole-prompt
    /// prefix, because the scripts are not always written that way. Roughly a
    /// third of them thread the extra detail *into* the instruction —
    /// "Continue straight." becomes "Continue straight through Byng Place.",
    /// "cross the road" becomes "cross the road using the zebra crossing" —
    /// so an exact prefix test finds nothing to dim on exactly the waypoints
    /// where the difference is most worth seeing.
    ///
    /// Returns nil when the two share too little to be worth splitting (some
    /// contextual scripts are written from scratch), in which case the caller
    /// shows the text whole.
    static func splitSharedPrefix(
        navigation: String,
        contextual: String
    ) -> (shared: String, added: String)? {
        let navigationWords = words(in: navigation)
        let contextualWords = words(in: contextual)
        guard !navigationWords.isEmpty, !contextualWords.isEmpty else { return nil }

        var matched = 0
        while matched < navigationWords.count,
              matched < contextualWords.count,
              normalised(navigationWords[matched]) == normalised(contextualWords[matched]) {
            matched += 1
        }

        guard matched >= minimumSharedWords, matched < contextualWords.count else { return nil }

        let shared = contextualWords[0..<matched].joined(separator: " ")
        let added = contextualWords[matched...].joined(separator: " ")
        guard !added.isEmpty else { return nil }
        return (shared, added)
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
