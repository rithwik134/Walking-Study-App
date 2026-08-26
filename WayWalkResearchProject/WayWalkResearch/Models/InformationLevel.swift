import Foundation

/// The two information conditions. Condition 1 plays only the navigation
/// prompt at each waypoint; Condition 2 plays only the contextual prompt,
/// which already contains the navigation instruction at its start. Exactly
/// one script is ever spoken per waypoint, never both.
enum InformationLevel: String, Codable, CaseIterable, Identifiable {
    case navigationOnly = "Navigation Only"
    case navigationPlusContext = "Navigation + Context"

    var id: String { rawValue }

    /// Compact label for segmented controls, where the full names are too
    /// wide to sit side by side on a narrow iPhone. `rawValue` is written into
    /// every CSV row and must not change to accommodate layout.
    var shortName: String {
        switch self {
        case .navigationOnly: return "Nav only"
        case .navigationPlusContext: return "Nav + context"
        }
    }

    /// One line describing what is actually spoken, for the setup screen.
    /// Kept to a single line — the setup screen is laid out to fit without
    /// scrolling, and a wrapped caption here pushes the test-mode toggle off.
    var explanation: String {
        switch self {
        case .navigationOnly:
            return "Only the navigation instruction is spoken."
        case .navigationPlusContext:
            return "The instruction plus surrounding context."
        }
    }
}

/// How a walk is being run: real data collection, a route test, or a manually
/// cued walk.
///
/// Recorded in the file name *and* in every row: a run that is not real data
/// but looks like a participant's session is worse than no recording at all,
/// and a file name alone is one rename away from being lost.
enum SessionMode: String, Codable, CaseIterable {
    /// Real data collection. Prompts fire automatically on arrival.
    case study
    /// Live waypoint map for checking positions and radii.
    case test
    /// Prompts do not fire on arrival — the researcher presses a button to
    /// play each one, with the trigger radius shown as a cue for roughly when.
    case manual

    /// Marker inserted into the file name. `SessionStore` looks for exactly
    /// these tokens when taking a file name back apart, so they must stay in
    /// sync with the parser.
    var fileNameMarker: String? {
        switch self {
        case .study: return nil
        case .test: return "TEST"
        case .manual: return "MANUAL"
        }
    }

    /// Whether this run produced something other than ordinary study data.
    var isMarked: Bool { fileNameMarker != nil }

    var displayName: String {
        switch self {
        case .study: return "Study"
        case .test: return "Test"
        case .manual: return "Manual"
        }
    }
}
