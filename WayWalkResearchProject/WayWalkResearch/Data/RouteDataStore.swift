import Foundation

/// Reads walk data from the app bundle's JSON files.
final class RouteDataStore {
    static let shared = RouteDataStore()

    private init() {}

    func loadWalk(_ id: WalkID) -> Walk? {
        guard let url = Bundle.main.url(forResource: id.dataFileName, withExtension: "json") else {
            print("No route data found for \(id.dataFileName)")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            print("Could not read route file at \(url)")
            return nil
        }
        guard let waypoints = try? JSONDecoder().decode([Waypoint].self, from: data) else {
            print("Could not decode \(url.lastPathComponent) — check it matches the Waypoint schema.")
            return nil
        }
        return Walk(id: id, waypoints: waypoints.sorted { $0.order < $1.order })
    }
}
