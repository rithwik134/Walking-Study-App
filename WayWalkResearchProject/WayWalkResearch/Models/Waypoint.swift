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

    /// How close, in metres, the participant must be for this waypoint's
    /// prompt to fire.
    ///
    /// **This is not the geofence radius.** The `CLCircularRegion` uses a
    /// fixed, much coarser `TriggerTuning.wakeRadius` (~100m) whose only job
    /// is to wake the app; the prompt itself fires when consecutive location
    /// fixes put the participant within *this* distance. See `WalkSession`
    /// for why the two were separated.
    ///
    /// It is also what the three maps draw to true scale, so keeping it the
    /// fire threshold is what keeps those circles honest.
    ///
    /// Consumer GPS in an urban street canyon is often ±10-15m, so values far
    /// below that will rarely be satisfied and will fall through to a
    /// backstop. Values above roughly half the smallest gap between
    /// consecutive waypoints let one position satisfy two waypoints at once.
    let triggerRadius: Double

    /// Condition 1 content — always played.
    let navigationPrompt: String

    /// Condition 2 content — played *instead of* the navigation prompt when
    /// Navigation + Context is selected. Expected to already contain the
    /// navigation instruction at its start, since only one of the two scripts
    /// is ever spoken per waypoint.
    ///
    /// Empty or absent means **this waypoint is not on the Navigation +
    /// Context route** — see `script(for:)`. It does *not* fall back to the
    /// navigation prompt.
    let contextualPrompt: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The one script spoken at this waypoint under a given condition.
    ///
    /// **An empty result means "not on this condition's route", not "silent".**
    /// There is deliberately no cross-condition fallback: the two Gordon
    /// Square branches are encoded as waypoints carrying a script for one
    /// condition only (`a10` navigation, `a11` contextual; `b21` navigation),
    /// and a fallback would make the wrong branch speak the wrong turn. See
    /// `WalkSession.armNextWaypoint()`, which skips such waypoints outright.
    ///
    /// The cost of dropping the fallback is that a waypoint authored with a
    /// forgotten `contextualPrompt` silently leaves the contextual route
    /// rather than borrowing the navigation prompt. `RouteDataTests` pins the
    /// exact off-route set per walk per condition so that cannot happen
    /// unnoticed.
    ///
    /// Lives here rather than in `WalkSession` so the researcher preview
    /// screens show exactly what will be spoken — if the two derived it
    /// separately they could quietly disagree.
    func script(for level: InformationLevel) -> String {
        switch level {
        case .navigationOnly:
            return navigationPrompt
        case .navigationPlusContext:
            return contextualPrompt
        }
    }

    /// Whether this waypoint is part of the route walked under `level`.
    ///
    /// Derived from `script(for:)` rather than from the raw fields, so there
    /// is exactly one definition of "has something to say here".
    func isOnRoute(for level: InformationLevel) -> Bool {
        !script(for: level).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
