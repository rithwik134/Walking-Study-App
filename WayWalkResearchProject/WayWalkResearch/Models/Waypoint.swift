import Foundation
import CoreLocation

/// A single trigger point along a walk. Everything a researcher needs to
/// edit — location, radius, script — lives here and nowhere else, so route
/// changes never require touching app code.
struct Waypoint: Codable, Identifiable, Equatable {
    let id: String
    let order: Int
    let name: String
    let latitude: Double
    let longitude: Double

    /// Geofence radius in metres. Keep this at 20m or above where possible —
    /// consumer GPS accuracy in an urban street canyon is often ±10-15m, so
    /// smaller radii can miss triggers or fire late.
    let triggerRadius: Double

    /// Condition 1 content — always played.
    let navigationPrompt: String

    /// Condition 2 content — played *instead of* the navigation prompt when
    /// Navigation + Context is selected. Expected to already contain the
    /// navigation instruction at its start, since only one of the two scripts
    /// is ever spoken per waypoint. Optional so a waypoint can fall back to
    /// the navigation prompt if no contextual script has been written yet.
    let contextualPrompt: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The one script spoken at this waypoint under a given condition,
    /// falling back to the navigation prompt if no contextual script has been
    /// written yet.
    ///
    /// Lives here rather than in `WalkSession` so the researcher preview
    /// screens show exactly what will be spoken — if the two derived it
    /// separately they could quietly disagree.
    func script(for level: InformationLevel) -> String {
        switch level {
        case .navigationOnly:
            return navigationPrompt
        case .navigationPlusContext:
            if let contextualPrompt, !contextualPrompt.isEmpty { return contextualPrompt }
            return navigationPrompt
        }
    }

    /// Filename stem used by `RecordedAudioPromptPlayer` to find this
    /// waypoint's recording for a given condition.
    func audioKey(for level: InformationLevel) -> String {
        switch level {
        case .navigationOnly: return "\(id)_nav"
        case .navigationPlusContext: return "\(id)_context"
        }
    }
}
