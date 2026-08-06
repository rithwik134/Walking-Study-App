import Foundation
import CoreLocation

/// Reads the precomputed walking paths from the app bundle, mirroring
/// `RouteDataStore`.
///
/// Returns `nil` when a path file has not been generated and committed yet —
/// callers fall back to drawing straight lines between waypoints, which is
/// what every map did before. A missing path degrades the picture, never the
/// walk.
final class RoutePathStore {
    static let shared = RoutePathStore()

    private var cache: [WalkID: RoutePath] = [:]

    private init() {}

    /// Filename (without extension) of the path JSON for a walk.
    static func fileName(for id: WalkID) -> String { "\(id.dataFileName)_path" }

    func path(for id: WalkID) -> RoutePath? {
        if let cached = cache[id] { return cached }

        guard let url = Bundle.main.url(forResource: Self.fileName(for: id), withExtension: "json") else {
            // Expected until the paths have been generated — not an error.
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            print("Could not read route path file at \(url)")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let path = try? decoder.decode(RoutePath.self, from: data) else {
            print("Could not decode \(url.lastPathComponent) — check it matches the RoutePath schema.")
            return nil
        }

        cache[id] = path
        return path
    }

    /// The line to draw for a walk: the routed path if one has been committed,
    /// otherwise the naive straight-line joining of the waypoints.
    func polyline(for walk: Walk) -> [CLLocationCoordinate2D] {
        Self.polyline(for: walk, routedPath: path(for: walk.id))
    }

    /// The fallback rule on its own, so it can be exercised for a walk whose
    /// path is missing without having to remove a file from the bundle.
    static func polyline(for walk: Walk, routedPath: RoutePath?) -> [CLLocationCoordinate2D] {
        routedPath?.locations ?? walk.waypoints.map(\.coordinate)
    }

    /// Whether the drawn line is the real routed one, so the UI can say so
    /// rather than letting a researcher assume a straight-line fallback is a
    /// routing failure.
    func hasRoutedPath(for id: WalkID) -> Bool { path(for: id) != nil }
}
