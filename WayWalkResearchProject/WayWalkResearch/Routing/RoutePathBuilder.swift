import Foundation
import MapKit

/// Authoring-time tool that turns a route's waypoints into a real walking
/// path using MKDirections, so the map can follow pavements and crossings
/// instead of drawing straight lines through buildings.
///
/// This is **not** used during a walk. It is run once per route by a
/// researcher on wifi; the result is exported as JSON, committed to the app
/// bundle, and read back at walk time by `RoutePathStore`. See `RoutePath`
/// for why.
///
/// Requests are issued strictly one leg at a time with a pause between them.
/// A 17-waypoint route is 16 requests, and firing those concurrently reliably
/// earns an `MKError.loadingThrottled`.
@MainActor
final class RoutePathBuilder: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var completedLegs = 0
    @Published private(set) var totalLegs = 0
    @Published private(set) var failedLegs: [Int] = []

    /// Pause between consecutive directions requests.
    private let interRequestDelay: Duration = .milliseconds(400)
    /// Attempts per leg before giving up on it.
    private let maxAttempts = 3

    enum BuilderError: LocalizedError {
        case notEnoughWaypoints

        var errorDescription: String? {
            switch self {
            case .notEnoughWaypoints:
                return "A route needs at least two waypoints to build a path."
            }
        }
    }

    /// Builds the full path. Legs that cannot be routed fall back to a
    /// straight line between their two waypoints and are reported in
    /// `failedLegs`, so a single unroutable segment does not throw away the
    /// other fifteen — but is also not silently hidden.
    func build(for walk: Walk) async throws -> RoutePath {
        let waypoints = walk.waypoints
        guard waypoints.count >= 2 else { throw BuilderError.notEnoughWaypoints }

        isBuilding = true
        completedLegs = 0
        failedLegs = []
        totalLegs = waypoints.count - 1
        defer { isBuilding = false }

        var coordinates: [CLLocationCoordinate2D] = []

        for legIndex in 0..<(waypoints.count - 1) {
            let from = waypoints[legIndex]
            let to = waypoints[legIndex + 1]

            let legCoordinates: [CLLocationCoordinate2D]
            if let routed = await routeLeg(from: from.coordinate, to: to.coordinate) {
                legCoordinates = routed
            } else {
                failedLegs.append(legIndex + 1)
                legCoordinates = [from.coordinate, to.coordinate]
            }

            append(legCoordinates, to: &coordinates)
            completedLegs = legIndex + 1

            if legIndex < waypoints.count - 2 {
                try? await Task.sleep(for: interRequestDelay)
            }
        }

        return RoutePath(walkID: walk.id, locations: coordinates)
    }

    /// One leg, with backoff on throttling. Returns nil once it has given up.
    private func routeLeg(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D]? {
        for attempt in 1...maxAttempts {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .walking
            request.requestsAlternateRoutes = false

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else { return nil }
                return Self.coordinates(of: route.polyline)
            } catch {
                let isThrottled = (error as? MKError)?.code == .loadingThrottled
                guard isThrottled, attempt < maxAttempts else { return nil }
                // Back off progressively — the throttle is time-based.
                try? await Task.sleep(for: .seconds(attempt * 2))
            }
        }
        return nil
    }

    /// Appends a leg, dropping the duplicate point where it meets the
    /// previous leg's end.
    private func append(_ leg: [CLLocationCoordinate2D], to path: inout [CLLocationCoordinate2D]) {
        guard let last = path.last else {
            path.append(contentsOf: leg)
            return
        }
        var leg = leg
        if let first = leg.first, Self.isSamePoint(first, last) {
            leg.removeFirst()
        }
        path.append(contentsOf: leg)
    }

    private static func isSamePoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: polyline.pointCount
        )
        polyline.getCoordinates(&result, range: NSRange(location: 0, length: polyline.pointCount))
        return result
    }

    // MARK: - Export

    /// Writes the generated path to `Documents/<walk>_path.json`, ready to be
    /// shared to a Mac and dropped into `WayWalkResearch/Data/`.
    static func export(_ path: RoutePath) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent("\(RoutePathStore.fileName(for: path.walkID)).json")
        try encoder.encode(path).write(to: url, options: .atomic)
        return url
    }
}
