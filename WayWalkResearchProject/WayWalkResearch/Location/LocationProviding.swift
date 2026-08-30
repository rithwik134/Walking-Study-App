import Foundation
import CoreLocation

/// The slice of `CLLocationManager` that `WalkSession` uses.
///
/// Exists so tests can supply a stand-in. `WalkSession` used to build its own
/// `CLLocationManager`, which meant a test could not stop it: the simulator
/// kept feeding real fixes into the session under test, and assertions about
/// distances silently depended on wherever the simulator's location happened
/// to be. That produced results that looked fine until the ambient location
/// moved — the worst kind of test, because it fails at random and passes when
/// re-run.
///
/// `CLLocationManager` already implements every member, so conformance is
/// declaration-only and runtime behaviour is unchanged.
protocol LocationProviding: AnyObject {
    var delegate: CLLocationManagerDelegate? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var allowsBackgroundLocationUpdates: Bool { get set }
    var pausesLocationUpdatesAutomatically: Bool { get set }
    var showsBackgroundLocationIndicator: Bool { get set }
    var monitoredRegions: Set<CLRegion> { get }
    var authorizationStatus: CLAuthorizationStatus { get }

    func requestAlwaysAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
    func requestState(for region: CLRegion)
}

extension CLLocationManager: LocationProviding {}
