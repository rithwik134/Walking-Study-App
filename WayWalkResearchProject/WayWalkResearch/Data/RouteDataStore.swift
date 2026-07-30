import Foundation

/// Reads walk data from JSON. On first launch, the bundled starter files are
/// copied into the app's Documents directory; every load after that reads
/// from Documents if a file exists there, falling back to the bundle copy
/// otherwise. This means route data can be edited — by hand via the Files
/// app, AirDrop, iCloud Drive, or eventually a map-based editor — without
/// rebuilding the app.
final class RouteDataStore {
    static let shared = RouteDataStore()

    private init() {
        copyBundledDefaultsIfNeeded()
    }

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func copyBundledDefaultsIfNeeded() {
        for id in WalkID.allCases {
            let destination = documentsURL.appendingPathComponent("\(id.dataFileName).json")
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            guard let bundled = Bundle.main.url(forResource: id.dataFileName, withExtension: "json") else {
                print("Missing bundled route file: \(id.dataFileName).json — add it to the app target.")
                continue
            }
            try? FileManager.default.copyItem(at: bundled, to: destination)
        }
    }

    func loadWalk(_ id: WalkID) -> Walk? {
        let documentsFile = documentsURL.appendingPathComponent("\(id.dataFileName).json")
        let sourceURL = FileManager.default.fileExists(atPath: documentsFile.path)
            ? documentsFile
            : Bundle.main.url(forResource: id.dataFileName, withExtension: "json")

        guard let url = sourceURL else {
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

    /// Useful for debugging — prints where to find the editable JSON on device
    /// (visible in the Files app if "Supports opening files in place" / a
    /// document-browser entitlement is enabled, or via Xcode's device file browser).
    var documentsPathDescription: String { documentsURL.path }
}
