# AGENTS.md

Repository guidance for coding agents. Read the relevant source and tests before making a change; this file records the important contracts but does not replace them.

## What this is

An iOS research instrument (SwiftUI + MapKit + CoreLocation), not a consumer app. It plays pre-written audio prompts at fixed GPS waypoints along two fixed routes, comparing navigation-only vs. navigation+context information for visually impaired pedestrians. The deliverable of a run is a CSV; a lost or contaminated session cannot be re-recorded, so logging correctness outranks everything else.

`README.md` at the repo root is the researcher-facing manual and the authoritative source for study procedure, CSV semantics, and the measured trigger-radius calibration. Read it before changing anything that touches logging, trigger radii, or session modes — much of what looks like an odd design choice is documented there and in the source doc comments (which are unusually detailed and explain *why*, often citing the bug that motivated the current shape).

## Commands

Run the Xcode commands below from `WayWalkResearchProject/`. The iOS target supports iOS 17.0+ on iPhone, uses Swift 5, and has no external dependencies. The separate route-path generator is a SwiftPM executable run from the repository root.

```bash
# Full XCTest suite
xcodebuild test -project WayWalkResearch.xcodeproj -scheme WayWalkResearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# One test class or one test
xcodebuild test -project WayWalkResearch.xcodeproj -scheme WayWalkResearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:WayWalkResearchTests/SessionLoggerTests
  # …/SessionLoggerTests/testAttachNoteDoesNotChangeTheTimestamp

# Build only
xcodebuild build -project WayWalkResearch.xcodeproj -scheme WayWalkResearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

There is no linter and no CI. Pick a simulator from `xcrun simctl list devices available`.

## Xcode project gotcha

`project.pbxproj` uses **explicit `PBXFileReference` entries, not file-system-synchronized groups**. A new `.swift` file dropped into a directory will not compile until it is added to the pbxproj (`PBXFileReference` + `PBXBuildFile` + the group's `children` + the target's `Sources` phase). Same for a new JSON resource, which also needs a `Resources` phase entry. `RecordedWaypointAudio/` is a *folder reference*, so MP3s added inside it are picked up automatically and keep their subdirectory at build time — which is why lookups pass `subdirectory: "RecordedWaypointAudio"`.

## Architecture

Data flows one way: bundled JSON → `WalkSession` → audio out + CSV to disk. There is no network at walk time, no in-app route editing, and no Documents copy of route data — changing a route means replacing JSON and rebuilding.

**`Location/WalkSession.swift`** is the engine and holds nearly all the behavioural risk. Its non-obvious contract:

- **Triggering is two-stage, and the split is the whole design.** The `CLCircularRegion` is a *coarse wake-up* at `TriggerTuning.wakeRadius` (100m); entering it fires **nothing** (`handleWakeEntry` only latches `hasEnteredWakeRegion`). The prompt fires from the fix stream in `evaluateTrigger` when `confirmingFixCount` consecutive fixes, each within `triggerAccuracyLimit` accuracy, land inside `waypoint.triggerRadius`. Reintroducing a fire in `handleWakeEntry` chain-fires the route — iOS reports "inside" from ~100m out and waypoints are a median ~50m apart, so N+1 is usually already "inside" when armed. `TwoStageTriggerTests.testWakeRegionEntryNeverFiresAnything` is the regression net.
- **Distance-based *triggering* is correct now; distance-based *cancellation of a timer* is still wrong.** The old bug was a single noisy fix cancelling a wall-clock dwell. There is no timer any more — an out-of-radius fix resets a run that the same stream must re-earn, which is symmetric. An unusable-accuracy fix is skipped entirely: it neither confirms nor resets.
- **Exactly one region is monitored at a time.** Waypoint N+1 is armed only after N has fired, so a waypoint that never fires blocks the *entire rest of the walk*. Three things guard that: `playCurrentWaypoint()` (the researcher's failsafe, deliberately unconditional and callable from any distance), and two automatic backstops — wake-region exit and "receded well past a close approach" — both logged as `.automatic` with a `backstop: …` note.
- `clearConfirmationProgress()` resets the run counters on every delivery path. Its predecessor cleared a `pendingWaypointID` that, left set, silently killed the walk; that property is gone, but do not add state a trigger path reads as "already in progress" without the same care.
- **Manual mode never auto-fires** — neither the fine trigger nor either backstop. `evaluateTrigger` still maintains `isInsideCurrentRadius` (the cue-button hint) and returns before delivering. All paths funnel through `deliverPrompt(for:at:source:note:)` so logging and advancement cannot drift between modes.
- **The first on-route waypoint requires a manual trigger** in study and test modes. `awaitingFirstManualTrigger` is set true at `start()` (except in manual mode) and cleared in `deliverPrompt()`. While true, the auto-trigger and both backstops are suppressed identically to manual mode, but `isInsideCurrentRadius` and `isConfirmingArrival` still update so the researcher sees arrival cues. This ensures the researcher explicitly begins the walk, preventing a premature first prompt before the participant is ready.
- Location fixes are processed **one at a time, in order, for every fix in the batch** — iOS coalesces updates while locked, so one delivery can contain an entire approach. Order within each fix matters: snapshot → closest-approach → trigger. `closestApproachAccuracyLimit` (50m) is deliberately looser than `triggerAccuracyLimit` (25m): good enough to measure with is not good enough to fire on.
- `currentLatitude`/`currentLongitude`/`currentAccuracy` are **computed from `currentFix`**, so a logged position and its `fix_time_local` can never come from different fixes.

**Protocol seams**, both existing purely for testability/swappability:

- `LocationProviding` — the slice of `CLLocationManager` `WalkSession` uses. Tests inject `SilentLocationManager` so simulator location cannot leak into distance assertions.
- `AudioPromptPlaying` — `RecordedAudioPromptPlayer` (wired up in `Views/HomeView.swift`) plays `<waypointID>_nav.mp3` / `<waypointID>_context.mp3` and falls back to TTS per-prompt when a file is missing; `SpeechPromptPlayer` is pure TTS. Both keep their **own** prompt queue with a 1.2s gap and **per-utterance completion handlers** — a single stored handler dropped completions when close waypoints queued, and `AVAudioPlayer` has no queue of its own so a second file would cut the first off mid-word. All 111 currently on-route scripts have matching MP3s; `RouteDataTests.testEveryOnRouteWaypointHasItsRecording` checks this.

**`Data/SessionLogger.swift`** rewrites the whole CSV atomically after *every* event (~25 rows / 4 KB). It buys crash safety at every step during a 20-40 minute locked-screen walk, and lets a flag's optional note be patched into an already-written row. `SessionLogger.columns` is the single source of truth for header and row order. Waypoint rows carry **two** distance columns that must not be conflated: `closest_approach_m` (minimum over usable fixes during the approach) and `trigger_distance_m` (distance calculated from the latest fix when the prompt was delivered). They can diverge by tens of metres on a backstop row. Identify backstops by the `backstop:` note, **not** by comparing closest approach with the trigger radius: a fix accurate enough for the 50 m closest-approach measurement can lie inside the radius yet be too inaccurate for the 25 m trigger confirmation. `fix_age_s` is derived from two values *stored on the event* (`timestamp` and `fixTimestamp`) rather than computed at write time — a value recomputed during `flush()` would drift on every rewrite and silently mutate already-written rows. "Undo last flag" *removes* the event without renumbering, so a gap in `event_index` is an honest record of a retraction.

Waypoint CSV time and distance are stamped **when `deliverPrompt` decides to deliver and queues playback**. If a prior prompt is still speaking, the new one is heard later; actual audible start time is not logged. Analyse `fix_age_s` and the possible audio queue delay before treating `trigger_distance_m` as where the participant heard the instruction.

**Enum raw values are the data format.** `SessionEventType`, `TriggerSource`, `SessionMode`, `InformationLevel`, and `WalkID` raw values are written verbatim into CSV columns and consumed by a desktop analyser. Renaming one silently breaks past-and-future data comparability; add display-only computed properties (`shortName`, `displayName`) instead. `SessionMode.fileNameMarker` is additionally parsed back out of file names by `SessionStore`, so the two must stay in sync.

**One script per waypoint, never both.** `Waypoint.script(for:)` is the only place the condition→text mapping lives, so preview cards and playback cannot disagree. The contextual script already contains the navigation instruction at its start; they are alternatives, never concatenated.

**An empty script means *off route*, not *silent*.** There is deliberately **no cross-condition fallback** in `script(for:)` — a missing contextual script does not borrow the navigation prompt. `WalkSession.armNextWaypoint()` skips a waypoint that fails `isOnRoute(for:)`: never armed, never spoken, never logged, in all three modes. This is how the two conditions take different paths through Gordon Square (`a10` navigation / `a11` contextual; `b21` navigation, with `b20`'s script carrying the contextual route). Firing them regardless is not a cosmetic bug in either direction: arming `a11` during a Navigation Only walk *blocked the rest of Walk A* — it sits ~33m away across the square, outside its 10m radius, and the seeded closest approach already exceeded `backstopApproachDistance` so the recede backstop's guard never opened. `SimulatedWalkTests.testEveryConditionWalksItsWholeRouteWithoutStalling` walks both routes in both conditions and is the regression net. `RouteDataTests` pins the exact off-route set per condition — that pin is what makes removing the fallback safe, since a waypoint authored with a forgotten `contextualPrompt` would otherwise vanish from the contextual route unnoticed.

`contextualPrompt` is a non-optional `String`, so `Waypoint` has a hand-written `init(from:)` that defaults an absent JSON key to `""` — the synthesised decoder treats it as required, which turns one hand-edited waypoint into a `keyNotFound` that fails the *whole route file* and stops the walk starting at all. Defaulting keeps the blast radius at one waypoint and routes it into the off-route behaviour above. That custom decoder suppresses the memberwise init, so the explicit one beside it is load-bearing: **a new `Waypoint` property must be added to both**.

Consequences to keep in mind: a CSV has fewer waypoint rows than the route has waypoints, and the count differs by condition (Walk A 26 / 28, Walk B 27 / 30); the researcher screens must show `Walk.routeLength(for:)` as the denominator, never `waypoints.count`; and `currentWaypointNumber` skips values, which is correct — it stays equal to the waypoint's `order`, which is what lets it be read against the map and the CSV. The empty-script guard in `playPrompt` is now unreachable and kept only as a backstop.

**Three researcher screens off `HomeView`**, selected by mutually exclusive Modes toggles: `ActiveWalkView` (study), `WaypointTestView` (test), `ManualWalkView` (manual). All three maps share `WaypointMapContent` and `WaypointPreviewCard`, and draw trigger radii to true scale, each waypoint at its own — at 5-17m they are sub-pixel until zoomed well in, which is deliberate. The circle is the *fire* radius; the 100m CoreLocation wake region is not drawn, because it fires nothing.

**`Routing/RoutePathBuilder.swift`** is authoring-time only, never used during a walk: it drives `MKDirections` one leg at a time with an 800ms gap (Apple's throttling is cumulative) and produces `walkA_path.json` / `walkB_path.json`, which are committed and read from the bundle so every participant sees an identical line offline. The drawn line is decoration; navigation ground truth is always the prompts in the route JSON. A missing path file degrades to straight lines between waypoints, not an error.

## Route data

`walkA.json` / `walkB.json` are flat `[Waypoint]` arrays (29 and 31 waypoints), sorted by `order` at load. Author them with `waypoint-picker.html` — a standalone Leaflet page that exports the exact schema `RouteDataStore` expects.

**`triggerRadius` is per waypoint** — the distance at which a prompt fires, **not** a geofence radius. 10 m is the default and covers 50 of 60 waypoints. Current exceptions are `a22`/`b9` at 17 m, `a27` at 8 m, and `a4`/`a19`/`a28`/`b5`/`b13`/`b16`/`b29` at 5 m. `RouteDataTests.testTriggerRadiiMatchTheirCalibratedValues` pins every radius individually, so update its expected values when deliberately changing a radius. Do not reintroduce a single global radius constant; nothing in `WalkSession` assumes one. Closely spaced waypoints are viable because only one is armed at a time.

Moving or renumbering waypoints invalidates the routed path files. Regenerate both on the Mac:

```bash
swift run --package-path Tools/GenerateRoutePaths GenerateRoutePaths
```

`Tools/GenerateRoutePaths/` is a standalone SwiftPM executable (not in the Xcode project) that mirrors `RoutePathBuilder` for each leg and writes `walkA_path.json` / `walkB_path.json` straight into `Data/`. It needs network, takes a few minutes for ~58 legs and a one-minute pause between walks, prints any leg that fell back to a straight line, and exits non-zero if any did. The pause prevents cumulative MapKit throttling seen near the end of Walk B. The in-app **View route map → ⋯ → Generate routed path…** flow still works and is the fallback; it ends with the files in the phone's Documents directory needing a manual share. Either way, eyeball the line before committing. Expect Walk A to double back ~33m through Gordon Square — the path is routed over the union of both condition branches, and it is decoration, not navigation.

The project has a committed `DEVELOPMENT_TEAM` and bundle ID (`com.testwalk.waywalkresearch`). Use your own signing settings if you do not have access to that team.

## When touching logging or triggering

`SessionLoggerTests` and `ClosestApproachTests` are the regression net for the CSV and for radius-sizing data; `AudioPromptPlayerTests` covers overlapping-prompt completions (a real past bug). Any change to `WalkSession`'s arm/confirm/deliver sequence, to the CSV columns, or to a prompt player's queue should come with a test there, and the full suite must pass before the change is considered done.
