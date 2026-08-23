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

/// Whether a walk is real data collection or a researcher testing the route.
///
/// Recorded in the file name *and* in every row: a test run that looks like a
/// participant's session is worse than no recording at all, and a file name
/// alone is one rename away from being lost.
enum SessionMode: String, Codable {
    case study
    case test

    var isTest: Bool { self == .test }
}
