import Foundation
import CoreLocation
import MapKit

// Regenerates walkA_path.json / walkB_path.json on the Mac, writing straight
// into WayWalkResearch/Data/.
//
// The app can already do this — View route map → ⋯ → Generate routed path… —
// but that flow ends with the file in the phone's Documents directory, needing
// a share and a manual drop onto the Mac for each of the two routes. This is
// the same algorithm without the round trip.
//
// It must stay behaviourally identical to
// WayWalkResearch/Routing/RoutePathBuilder.swift, because the files it writes
// are committed and read back by the app. In particular: walking transport, one
// leg at a time, 800ms between requests, backoff on throttling only, straight
// line fallback for a leg that cannot be routed, duplicate join points dropped,
// and pretty-printed JSON with sorted keys.
//
//   swift run --package-path Tools/GenerateRoutePaths GenerateRoutePaths
//
// Needs a network connection. Both routes back to back is ~58 directions
// requests and takes a couple of minutes.

// MARK: - The subset of the app's models this needs

enum WalkID: String, Codable, CaseIterable {
    case walkA
    case walkB

    var dataFileName: String { rawValue }
    var pathFileName: String { "\(rawValue)_path" }
}

struct Waypoint: Codable {
    let id: String
    let order: Int
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Field-for-field identical to the app's `RoutePath`, including the flat
/// `[[lat, lng]]` coordinate encoding.
struct RoutePath: Codable {
    let walkID: WalkID
    let generatedAt: Date
    let coordinates: [[Double]]

    init(walkID: WalkID, generatedAt: Date = Date(), locations: [CLLocationCoordinate2D]) {
        self.walkID = walkID
        self.generatedAt = generatedAt
        self.coordinates = locations.map { [$0.latitude, $0.longitude] }
    }
}

// MARK: - Locating the repo

/// Walks up from this file to the repository root, so the tool works from any
/// working directory. `#filePath` is the one thing here that cannot be wrong.
let dataDirectory: URL = {
    var url = URL(fileURLWithPath: #filePath)          // …/Tools/GenerateRoutePaths/Sources/main.swift
        .deletingLastPathComponent()                   // …/Sources
        .deletingLastPathComponent()                   // …/GenerateRoutePaths
        .deletingLastPathComponent()                   // …/Tools
        .deletingLastPathComponent()                   // repo root
    url.appendPathComponent("WayWalkResearchProject/WayWalkResearch/Data")
    return url
}()

func loadWaypoints(_ walk: WalkID) throws -> [Waypoint] {
    let url = dataDirectory.appendingPathComponent("\(walk.dataFileName).json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([Waypoint].self, from: data).sorted { $0.order < $1.order }
}

// MARK: - Routing

let interRequestDelay: Duration = .milliseconds(800)
let maxAttempts = 4

func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
    var result = [CLLocationCoordinate2D](
        repeating: CLLocationCoordinate2D(), count: polyline.pointCount
    )
    polyline.getCoordinates(&result, range: NSRange(location: 0, length: polyline.pointCount))
    return result
}

func isSamePoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
    abs(a.latitude - b.latitude) < 1e-7 && abs(a.longitude - b.longitude) < 1e-7
}

/// Appends a leg, dropping the duplicate point where it meets the previous
/// leg's end.
func append(_ leg: [CLLocationCoordinate2D], to path: inout [CLLocationCoordinate2D]) {
    guard let last = path.last else {
        path.append(contentsOf: leg)
        return
    }
    var leg = leg
    if let first = leg.first, isSamePoint(first, last) {
        leg.removeFirst()
    }
    path.append(contentsOf: leg)
}

/// One leg, with backoff on throttling. Returns nil once it has given up.
func routeLeg(
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
            return coordinates(of: route.polyline)
        } catch {
            let isThrottled = (error as? MKError)?.code == .loadingThrottled
            guard isThrottled, attempt < maxAttempts else {
                if !isThrottled {
                    FileHandle.standardError.write(
                        Data("      \(error.localizedDescription)\n".utf8)
                    )
                }
                return nil
            }
            print("      throttled, backing off \(attempt * 2)s (attempt \(attempt)/\(maxAttempts))")
            try? await Task.sleep(for: .seconds(attempt * 2))
        }
    }
    return nil
}

func build(_ walk: WalkID) async throws -> (path: RoutePath, failedLegs: [Int]) {
    let waypoints = try loadWaypoints(walk)
    guard waypoints.count >= 2 else {
        throw NSError(domain: "GenerateRoutePaths", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(walk.rawValue) needs at least two waypoints."
        ])
    }

    print("\(walk.rawValue): \(waypoints.count) waypoints, \(waypoints.count - 1) legs")

    var coordinates: [CLLocationCoordinate2D] = []
    var failedLegs: [Int] = []

    for legIndex in 0..<(waypoints.count - 1) {
        let from = waypoints[legIndex]
        let to = waypoints[legIndex + 1]

        if let routed = await routeLeg(from: from.coordinate, to: to.coordinate) {
            append(routed, to: &coordinates)
            print("  leg \(legIndex + 1)/\(waypoints.count - 1)  \(from.id) → \(to.id)  \(routed.count) points")
        } else {
            // A single unroutable segment must not throw away the other fifty,
            // but it must not be hidden either — a straight line through a
            // building is exactly what the researcher needs to see on the map.
            failedLegs.append(legIndex + 1)
            append([from.coordinate, to.coordinate], to: &coordinates)
            print("  leg \(legIndex + 1)/\(waypoints.count - 1)  \(from.id) → \(to.id)  FAILED — straight line")
        }

        if legIndex < waypoints.count - 2 {
            // Apple's throttling is cumulative across requests, so the pause
            // matters most on a long route and on the second route of a run.
            try? await Task.sleep(for: interRequestDelay)
        }
    }

    return (RoutePath(walkID: walk, locations: coordinates), failedLegs)
}

// MARK: - Run

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

var anyFailures = false

for walk in WalkID.allCases {
    let (path, failedLegs) = try await build(walk)
    let url = dataDirectory.appendingPathComponent("\(walk.pathFileName).json")
    try encoder.encode(path).write(to: url, options: .atomic)

    print("  → \(url.path)")
    print("  \(path.coordinates.count) coordinates")
    if failedLegs.isEmpty {
        print("  every leg routed\n")
    } else {
        anyFailures = true
        print("  \(failedLegs.count) leg(s) fell back to a straight line: \(failedLegs)\n")
    }
}

print("Check both lines on the route map before committing — Apple's pedestrian")
print("data does not always include garden paths and internal campus routes.")

if anyFailures { exit(2) }
