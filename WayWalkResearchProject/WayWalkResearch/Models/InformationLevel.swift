import Foundation

/// The two information conditions. Condition 1 plays only the navigation
/// prompt at each waypoint; Condition 2 plays only the contextual prompt,
/// which already contains the navigation instruction at its start. Exactly
/// one script is ever spoken per waypoint, never both.
enum InformationLevel: String, CaseIterable, Identifiable {
    case navigationOnly = "Navigation Only"
    case navigationPlusContext = "Navigation + Context"

    var id: String { rawValue }
}
