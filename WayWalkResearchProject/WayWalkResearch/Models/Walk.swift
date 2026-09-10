import Foundation

/// The two fixed routes in the experiment. Each is stored as its own JSON
/// file, so the two directions can have genuinely different trigger points
/// and scripts rather than being derived from a single reversed list.
enum WalkID: String, Codable, CaseIterable, Identifiable {
    case walkA
    case walkB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .walkA: return "Walk A — UCL Main Entrance → Central House"
        case .walkB: return "Walk B — Central House → UCL Main Entrance"
        }
    }

    /// Filename (without extension) of the JSON this walk loads from.
    var dataFileName: String { rawValue }
}

struct Walk: Identifiable {
    let id: WalkID
    let waypoints: [Waypoint]

    var displayName: String { id.displayName }

    /// How many waypoints are actually walked under `level`.
    ///
    /// Lower than `waypoints.count` whenever the route branches by condition —
    /// `WalkSession` skips waypoints with no script for the running condition,
    /// so this, not the raw count, is the denominator the researcher screens
    /// must show. "Waypoint 12 of 29" on a 21-waypoint route reads as a fault.
    func routeLength(for level: InformationLevel) -> Int {
        waypoints.filter { $0.isOnRoute(for: level) }.count
    }
}
