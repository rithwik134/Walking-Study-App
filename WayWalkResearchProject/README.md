# WayWalk Research

A SwiftUI/MapKit iOS app for delivering pre-written audio prompts at fixed
GPS waypoints, for a study comparing basic vs. contextual navigation
information for visually impaired pedestrians.

## Opening the project

Double-click **`WayWalkResearch.xcodeproj`**. Xcode opens it directly — no
manual file-adding required, everything is already wired into the project.

## Before your first build

1. Select the **WayWalkResearch** target → **Signing & Capabilities**.
2. Under **Signing**, choose your own **Team** (the project ships with no
   team set, since that's tied to your personal Apple ID).
3. Change **Bundle Identifier** from `com.example.waywalkresearch` to
   something under your own domain, e.g. `com.yourname.waywalkresearch`.
4. Build target: **iOS 17.0+**, iPhone only. Plug in a device or pick an
   iPhone simulator and hit Run.

Everything else — the two background modes (Location updates, Audio) and
the location usage descriptions — are already set directly in
`WayWalkResearch/Info.plist`, so there's nothing else to configure in
Signing & Capabilities.

## Project layout

```
WayWalkResearch.xcodeproj/       ← open this
WayWalkResearch/
  WayWalkResearchApp.swift       ← app entry point
  Models/                        ← Waypoint, Walk, InformationLevel
  Data/
    RouteDataStore.swift         ← loads/persists route JSON
    walkA.json, walkB.json       ← sample route data — replace with your real route
  Audio/
    AudioPromptPlaying.swift     ← protocol
    SpeechPromptPlayer.swift     ← speech synthesis (used today)
    RecordedAudioPromptPlayer.swift ← drop-in replacement once you have recordings
  Location/
    WalkSession.swift            ← geofencing + one-shot triggering engine
  Views/
    HomeView.swift                ← Select Walk / Select Information Level / Start
    ActiveWalkView.swift          ← researcher-facing status screen during a walk
    RouteMapView.swift            ← MapKit overview of both walks, for checking
  Assets.xcassets/                ← empty AppIcon slot + AccentColor (add a real icon before App Store submission)
  Info.plist
waypoint-picker.html              ← browser tool for placing waypoints on a map and exporting walkA.json / walkB.json
```

## Editing routes

Use `waypoint-picker.html` (works in any browser, no install needed) to
click waypoints onto a real map, set names/radii/prompts, and export
`walkA.json` / `walkB.json` in the exact schema `RouteDataStore` expects.
Drop the exported files into `WayWalkResearch/Data/`, replacing the samples,
then rebuild.

Route data is copied into the app's Documents directory on first launch, so
after that, edits to the Documents copy take priority over the bundled
files — see the in-code comments in `RouteDataStore.swift` for details on
how to push updated JSON to a device directly without reinstalling.

## Known iOS constraints

- **Geofences are monitored one at a time, sequentially.** Only the current
  waypoint's region is ever registered with `CLLocationManager`; the next
  one isn't armed until the current one has fired. This is what prevents
  overlapping trigger zones from misfiring — the system-wide 20-region
  limit is no longer a practical concern for this app.
- **Geofence accuracy**: realistically ±15-20m in good conditions, worse
  near tall buildings. Keep trigger radii realistic for the environment —
  radii much smaller than the GPS noise floor (e.g. 5m) risk missed or
  late triggers even though the sequential logic itself is reliable.
- **Locked-phone playback** depends on the Background Modes already baked
  into Info.plist — test explicitly (lock the phone, walk into a trigger
  zone, confirm audio plays) before the real study.
- **Bone-conduction headphones** are handled as a standard Bluetooth audio
  output; no extra code needed beyond the audio session options already set
  in `SpeechPromptPlayer`.
- **Audio interruptions** (calls, notifications, Siri) are caught via
  `AVAudioSession.interruptionNotification` — speech pauses on interruption
  and automatically resumes afterward, rather than stopping permanently.

## Testing tools

- **Debug button**, on the researcher screen during a normal walk, reveals
  a small panel with live GPS accuracy, current waypoint number, distance
  to the next waypoint, latitude/longitude, and whether the next waypoint
  is currently armed. Hidden by default.
- **Waypoint Test Mode**, toggled on the Home screen before starting a
  walk, replaces the normal researcher screen with a live map showing every
  waypoint, your current position, which waypoint is armed (orange), and
  which have already triggered (green) — useful for fine-tuning waypoint
  positions and radii before real data collection.

## Swapping in recorded audio later

Add files named to match each waypoint (e.g. `a2_nav.mp3`,
`a2_context.mp3`) to the app bundle, then change one line in `HomeView`:

```swift
@StateObject private var session = WalkSession(audioPlayer: RecordedAudioPromptPlayer())
```

Nothing else changes — the triggering logic, Home screen, and active-walk
screen all depend only on the `AudioPromptPlaying` protocol, not on speech
synthesis specifically.
