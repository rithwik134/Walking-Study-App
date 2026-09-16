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
    ///
    /// Non-optional, but still optional *in the JSON*: `init(from:)` below
    /// defaults an absent key to `""`.
    let contextualPrompt: String

    /// Decodes an absent `contextualPrompt` as `""` rather than failing.
    ///
    /// The synthesised decoder treats a non-optional property as a required
    /// key, which turns one hand-authored waypoint missing the field into a
    /// `keyNotFound` that fails the **whole file** — every waypoint on the
    /// route, not just that one, so the walk cannot start at all. Defaulting
    /// here keeps the blast radius at one waypoint and routes it into the
    /// behaviour already documented above: absent reads as empty, which means
    /// off the Navigation + Context route. `RouteDataTests` pins the exact
    /// off-route set, so an accidental omission still fails the suite rather
    /// than going unnoticed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
        name = try container.decode(String.self, forKey: .name)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        triggerRadius = try container.decode(Double.self, forKey: .triggerRadius)
        navigationPrompt = try container.decode(String.self, forKey: .navigationPrompt)
        contextualPrompt = try container.decodeIfPresent(String.self, forKey: .contextualPrompt) ?? ""
    }

    init(
        id: String,
        order: Int,
        name: String,
        latitude: Double,
        longitude: Double,
        triggerRadius: Double,
        navigationPrompt: String,
        contextualPrompt: String
    ) {
        self.id = id
        self.order = order
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.triggerRadius = triggerRadius
        self.navigationPrompt = navigationPrompt
        self.contextualPrompt = contextualPrompt
    }

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
