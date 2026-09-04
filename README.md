# WayWalk Research

A SwiftUI/MapKit iOS app for delivering pre-written audio prompts at fixed
GPS waypoints, for a study comparing basic vs. contextual navigation
information for visually impaired pedestrians.

## Opening the project

Double-click **`WayWalkResearch.xcodeproj`**. Xcode opens it directly — no
manual file-adding required, everything is already wired into the project.

## Before your first build

A development team (`98SNX6UZ24`) and bundle identifier
(`com.testwalk.waywalkresearch`) are already committed under **Signing &
Capabilities**, so the project builds and runs as-is for anyone with access
to that team. Building under your **own** Apple ID instead:

1. Select the **WayWalkResearch** target → **Signing & Capabilities**.
2. Under **Signing**, choose your own **Team**.
3. Change **Bundle Identifier** to something under your own domain, e.g.
   `com.yourname.waywalkresearch`.
4. Build target: **iOS 17.0+**, iPhone only. Plug in a device or pick an
   iPhone simulator and hit Run.

Everything else — the two background modes (Location updates, Audio) and
the location usage descriptions — are already set directly in
`WayWalkResearch/Info.plist`, so there's nothing else to configure in
Signing & Capabilities.

## Running tests

```bash
xcodebuild test -project WayWalkResearch.xcodeproj -scheme WayWalkResearch \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

138 tests, ~30s, no simulator location or network required — `WalkSession` is
driven through the `LocationProviding` protocol with a stand-in that emits
only the fixes a test hands it. Covers the CSV (`SessionLoggerTests`), the
distance columns (`ClosestApproachTests`), the two-stage trigger and both
backstops (`TwoStageTriggerTests`), overlapping-prompt completions for both
audio backends (`AudioPromptPlayerTests`, which also covers the status
banner), and route/path JSON decoding (`RouteDataTests`, `RoutePathTests`).

`SimulatedWalkTests` is the one to run after touching triggering: it walks a
synthetic participant along the real walkA geometry at 1.4 m/s with realistic
GPS noise, and prints what fired, at what distance, and how far apart. It found
a bug the other 129 tests missed — the recede backstop was unreachable whenever
fixes were too imprecise to fire on, which is exactly when it is needed.

## Project layout

```
WayWalkResearch.xcodeproj/       ← open this
WayWalkResearch/
  WayWalkResearchApp.swift       ← app entry point
  Models/                        ← Waypoint, Walk, InformationLevel, SessionEvent, RoutePath
  Data/
    RouteDataStore.swift         ← loads route JSON from the app bundle
    walkA.json, walkB.json       ← real route data (28 and 27 waypoints)
    walkA_path.json, walkB_path.json ← precomputed walking paths (see "Routed map lines")
    RoutePathStore.swift         ← loads the precomputed paths
    SessionLogger.swift          ← writes one CSV per walk, as it happens
    SessionStore.swift           ← lists/deletes past session files
  Audio/
    AudioPromptPlaying.swift     ← protocol
    RecordedAudioPromptPlayer.swift ← used today; plays bundled MP3s, falls back to TTS per-prompt for any missing file
    RecordedWaypointAudio/       ← the MP3s themselves, e.g. a2_nav.mp3 / a2_context.mp3 (see "Recorded audio" below)
    SpeechPromptPlayer.swift     ← pure text-to-speech backend, no recordings needed
  Location/
    WalkSession.swift            ← geofencing + one-shot triggering engine + session logging
  Routing/
    RoutePathBuilder.swift       ← authoring-time MKDirections path generator
  Views/
    HomeView.swift                ← Participant / Select Walk / Information Level / Start
    ActiveWalkView.swift          ← researcher screen during a walk: map, prompt, flags
    RouteMapView.swift            ← MapKit overview of one walk at a time, for checking
    WaypointTestView.swift        ← live waypoint test mode
    ManualWalkView.swift          ← manual mode: researcher cues each prompt
    SessionsView.swift            ← past session CSVs, with share and delete
    RoutePathGeneratorView.swift  ← authoring UI for the routed paths
    Components/
      WaypointPreviewCard.swift   ← the waypoint detail card shared by all three maps
      WaypointMapContent.swift    ← waypoints, radii and route line, shared by all three maps
      WalkStatusBanner.swift      ← floating "Playing…" / "Walk ended" status pill
  Assets.xcassets/                ← empty AppIcon slot + AccentColor (add a real icon before App Store submission)
  Info.plist
WayWalkResearchTests/             ← XCTest suite, 138 tests (see "Running tests" above)
waypoint-picker.html              ← browser tool for placing waypoints on a map and exporting walkA.json / walkB.json
```

New `.swift` or resource files must also be added to `project.pbxproj` (file
reference, build file, group, and the target's Sources/Resources phase) or
Xcode will not compile them — this project does not use file-system
synchronized groups. `RecordedWaypointAudio/` is the one exception: it is a
folder reference, so MP3s dropped in there are picked up automatically.

## Editing routes

Use `waypoint-picker.html` (works in any browser, no install needed) to
click waypoints onto a real map, set names/radii/prompts, and export
`walkA.json` / `walkB.json` in the exact schema `RouteDataStore` expects.
Drop the exported files into `WayWalkResearch/Data/`, replacing the samples,
then rebuild.

Route data is read from the app bundle only — there is no Documents copy and
no in-app editing, so changing a route always means replacing the JSON and
rebuilding. If you move or renumber waypoints, regenerate the routed map
lines too (below).

## Recorded data

Every walk writes a CSV to `Documents/Sessions/` on the device, named
`WayWalk_<participant>_<walk>_<yyyyMMdd-HHmmss>.csv`. One row per event:
the session start, each waypoint as it fires, each flag the researcher
raises, and the session end.

Columns: `session_id, participant_id, walk, information_level, session_mode,
event_index, event_type, time_iso, time_local, elapsed_s, waypoint_order,
waypoint_id, waypoint_name, trigger_source, closest_approach_m,
trigger_distance_m, latitude, longitude, gps_accuracy_m, fix_time_local,
fix_age_s, note`.

Three timing details worth knowing:

- **`time_local` is bare `HH:MM:SS`** in the device's timezone, so waypoint
  rows paste directly into the `Zone,In,Out` file the WayWalk Analyser
  expects. `time_iso` carries the full date and UTC offset for the archive.
- **`time_local` is when the prompt started playing** — the moment the app
  decided, which is also the moment the participant heard it.
- **`fix_age_s` is how stale the position on that row was**, in seconds: the
  gap between when the GPS fix was *measured* (`fix_time_local`) and when the
  event was recorded. iOS batches location updates while the screen is
  locked — the normal state during a walk — so a row can carry coordinates
  taken twenty seconds and thirty metres earlier. A large value means the
  prompt fired late and the logged position is where they *were*, not where
  they were when it played. Blank means no fix was known at all.

### Forced prompts are marked

Every walk screen has a green **Play waypoint n** button. It is a failsafe: if
a geofence does not fire, the walk would otherwise stall there forever, since
the next waypoint is only armed once the current one fires. Pressing it plays
the instruction the participant was owed and unblocks the rest of the route.

Those rows carry `trigger_source = manual`; ones the participant's own arrival
produced carry `automatic`. **This distinction matters for analysis** — a forced
prompt is not evidence the participant was at that waypoint, and may mean they
were nowhere near it. Filter or annotate accordingly.

### Backstop fires are marked in `note`

A waypoint that never fires blocks the entire rest of the walk, since the next
one is only armed once the current one fires. So when the app can tell the
participant has *passed* a waypoint without ever getting close enough to
trigger it, it fires it anyway rather than let the walk stall. Those rows carry
`trigger_source = automatic` — the participant's own movement did cause them —
with a `note` of either:

| `note` | Meaning |
|---|---|
| `backstop: wake_exit` | They left the ~100 m monitoring region around the waypoint without ever confirming arrival |
| `backstop: receded` | They came within 30 m, then travelled 50 m past their closest point, without ever confirming arrival |

**A backstop row is not evidence of arrival**, and typically fires well after
the waypoint. Two ways to exclude them: filter on `note` starting `backstop:`,
or — if your analyser ignores `note` — on `closest_approach_m` exceeding the
waypoint's `triggerRadius`, which is true of every backstop row by definition,
since a row that got closer than that would have fired normally.

### Two different distances, and why you need both

Waypoint rows carry two distance columns. They answer different questions and
can differ by tens of metres:

| Column | Question it answers |
|---|---|
| `closest_approach_m` | **Did they ever get near this waypoint?** The minimum distance over the whole approach. The radius-sizing number. |
| `trigger_distance_m` | **Where were they when they heard it?** The distance at the moment the prompt played. |

For a clean automatic fire the two are nearly equal — the prompt plays at the
closest point. They diverge sharply on backstop rows. A simulated walk with
poor GPS produced this:

| waypoint | closest_approach_m | trigger_distance_m | note |
|---|---|---|---|
| a1 | 2.0 m | **59.2 m** | `backstop: receded` |
| a2 | 2.7 m | **54.2 m** | `backstop: receded` |

Read `closest_approach_m` alone and every one of those looks like a textbook
trigger. In fact the participant was told to turn roughly a minute after
walking past the turn. **For anything about whether an instruction arrived in
time to be useful, `trigger_distance_m` is the column to use.**

`trigger_distance_m` is measured from the same fix as `latitude`/`longitude`,
so read it against `gps_accuracy_m` and `fix_age_s` — with a stale or imprecise
fix it is where the app *believed* they were.

### How close they got: `closest_approach_m`

Every waypoint row records **the closest the participant actually got to that
waypoint while it was armed**, in metres. What it tells you depends on how the
row fired:

- **`automatic`, no note** — a normal fire. Should be at or inside the
  waypoint's `triggerRadius`; that is what firing means.
- **`automatic`, `backstop:` note** — how near they came without ever
  confirming arrival. Always larger than `triggerRadius`.
- **`manual`** — how near they came at the moment the researcher forced it.

Compare it with the waypoint's `triggerRadius` in the route JSON:

| Reading | What it means | What to do |
|---|---|---|
| Much larger than the radius | They never came close enough — a route or wayfinding problem, not a technical one | Check whether they went off-route |
| At or just outside the radius | They *were* there and no fix was accurate enough to confirm it | Loosen `triggerAccuracyLimit`, or widen the radius |
| Blank | No fix accurate enough to judge | Treat as unknown, not as zero |

Only fixes with a horizontal accuracy of 50 m or better contribute, so a vague
reading that happens to land near the waypoint cannot invent an approach the
participant never made. The value is seeded from the participant's position at
the moment the waypoint was armed, so a prompt cued before the next fix arrives
still reports a real distance instead of nothing.

### Why the trigger works the way it does

Prompts used to fire on CoreLocation region entry. They no longer do, because
iOS clamps small geofences upward and reports "inside" from far away. Measured
in the simulator here:

| Configured | Fired at |
|---|---|
| 15 m | 32.8 m |
| 5 m | 24.7 m, 28.0 m |

Not proportional — shrinking the configured radius barely moved the trigger
distance, pointing to a floor rather than a multiplier. Real-device figures are
far worse: Shevchenko & Reips (2023, *Behavior Research Methods* 56:6411)
walked iPhones past 10 m geofences and saw them fire **75-183 m out**, with no
difference between 10 m, 50 m and 100 m radii, concluding iOS likely uses ~100 m
for anything below 100 m.

With waypoints a median ~50 m apart on these routes, that does not merely fire
early — it **chain-fires**. Waypoint N fires, N+1 is armed, iOS immediately
reports the participant already inside N+1's clamped radius, and several
prompts stack up on someone standing still.

So triggering is now two-stage:

1. **A coarse 100 m region wakes the app.** Entering it plays nothing. Its only
   job is to guarantee the app is running — region monitoring is what Apple
   supports for relaunching a suspended app while the phone is locked.
2. **The prompt fires from the GPS fix stream**, when two consecutive fixes,
   each accurate to within 25 m, put the participant inside the waypoint's
   `triggerRadius` (currently 10 m).

`triggerRadius` in the route JSON is therefore **the distance at which a prompt
fires**, not a geofence radius — and it is what the maps draw to scale. The
backstops above exist because a waypoint that never fires would otherwise block
the rest of the walk.

**Both radius figures above are still worth re-measuring on the actual iPhone**
before a study, using `closest_approach_m`, `gps_accuracy_m` and `fix_age_s`
from a Test Mode walk. In particular, if `gps_accuracy_m` on the route is
routinely worse than 25 m, the fine trigger will starve and everything will
fall through to backstops — raise `TriggerTuning.triggerAccuracyLimit`.

The file is rewritten from scratch after every single event, so if the app
crashes or iOS terminates it mid-walk, everything up to that moment is
already on disk.

### Non-study runs are marked

The Home screen has a **Modes** section with two mutually exclusive toggles.
Both still record a session — they have to, or you could not check that logging
works before a real walk — so both are marked twice over, to stop either being
mistaken for participant data later:

| Mode | File name | Every row | Home screen |
|---|---|---|---|
| Normal walk | `WayWalk_<participant>_…` | `session_mode = study` | Start Walk |
| Waypoint Test Mode | `WayWalk_TEST_<participant>_…` | `session_mode = test` | Start Test Mode, orange |
| Manual Mode | `WayWalk_MANUAL_<participant>_…` | `session_mode = manual` | Start Manual Mode, indigo |

The marker is in the file name so it is obvious in a Finder listing without
opening anything, and in every row so it survives a rename. Past Sessions
badges them too. **Filter with `session_mode == "study"` before analysis.**

Three ways to get the files off the device, in rough order of convenience:

1. **Finder**, with the phone plugged into a Mac — the app appears under
   Files, and its Sessions folder can be dragged straight out.
2. **Files app** on the phone, under On My iPhone → WayWalk Research.
3. **Share sheet**, from the walk-complete screen or from Past Sessions
   (individually or all at once).

Nothing is deleted automatically. Past Sessions is where you remove files
once they are safely copied.

### Flags

The researcher screen has a large **Flag this moment** button. Pressing it
stamps and saves the timestamp immediately; a note sheet then opens and is
entirely optional — dismissing it without typing still leaves a valid,
timestamped flag. **Undo last flag** retracts a mis-tap, which leaves a
deliberate gap in `event_index` rather than renumbering, so the record shows
that something was withdrawn.

## Manual Mode

Prompts do not fire on arrival. The route, waypoints and trigger radii are
shown exactly as in a normal walk, but nothing is spoken until the researcher
presses **Play waypoint n**.

The button is grey outside the trigger radius and turns green on entering it,
so you can see roughly when a prompt is due — but it stays pressable either
way. That is deliberate: the radius is a hint about timing, not a gate.
Judging the right moment is the point of the mode, and a button that refused to
work until CoreLocation agreed would take that judgement away exactly when it
is wanted.

Green now means a GPS fix put the participant within the waypoint's
`triggerRadius` — about 10 m — rather than the much coarser CoreLocation
region entry it used to track. It therefore lights considerably later, and can
flicker at the boundary. That is the honest reading, and it matches the circle
drawn on the map; the **"n m away"** figure under the button is the better cue
for anticipating a prompt.

Pressing plays the current waypoint and advances to the next one, so the walk
progresses at the researcher's pace rather than the geofence's. Pressing again
before the previous prompt has finished **queues** the new one rather than
cutting it off.

Manual rows record `time_local` (when the button was pressed) and
`closest_approach_m` (the nearest the participant got to that waypoint). The
arrival instant is not recorded separately, so the wait between reaching a
waypoint and being cued is not measurable from the log — add a
`region_entry_local` column if that gap matters.

## Routed map lines

`walkA_path.json` / `walkB_path.json` hold a precomputed walking path for
each route, so the maps follow pavements and crossings instead of drawing
straight lines through buildings. They are committed to the repo and read
from the app bundle — no network is needed during a walk, and every
participant sees an identical line.

The line is decoration for the researcher. Navigation ground truth is, and
remains, the pre-written prompts in the route JSON.

To regenerate after moving waypoints: open **View route map**, pick the walk,
then the **⋯** menu → **Generate routed path…**. It routes each consecutive
pair of waypoints in turn (27 requests for Walk A's 28 waypoints, deliberately
serial — Apple throttles bursts), reports any legs it could not route, and
hands you a JSON file to share. Put that file in `WayWalkResearch/Data/`,
make sure it is in the target's Copy Bundle Resources phase, rebuild, and
**check the drawn line by eye before committing** — Apple's pedestrian data
does not always include garden paths and internal campus routes.

## Known iOS constraints

- **Geofences are monitored one at a time, sequentially.** Only the current
  waypoint's region is ever registered with `CLLocationManager`; the next
  one isn't armed until the current one has fired. This is what prevents
  overlapping trigger zones from misfiring — the system-wide 20-region
  limit is no longer a practical concern for this app.
- **Geofences cannot be used to fire prompts precisely.** iOS clamps small
  radii upward and reports entry from ~100 m away, so region monitoring is
  used only to wake the app; the prompt fires from GPS fixes. See "Why the
  trigger works the way it does" above.
- **GPS accuracy**: realistically ±15-20m in good conditions, worse near
  tall buildings. A fire radius far below that will rarely be satisfied and
  will fall through to a backstop; one above roughly half the smallest gap
  between consecutive waypoints lets one position satisfy two waypoints.
- **Locked-phone playback** depends on the Background Modes already baked
  into Info.plist — test explicitly (lock the phone, walk into a trigger
  zone, confirm audio plays) before the real study.
- **Bone-conduction headphones** are handled as a standard Bluetooth audio
  output; no extra code needed beyond the audio session options already set
  in `RecordedAudioPromptPlayer` / `SpeechPromptPlayer`.
- **Audio interruptions** (calls, notifications, Siri) are caught via
  `AVAudioSession.interruptionNotification` in both audio backends — playback
  pauses on interruption and automatically resumes afterward, rather than
  stopping permanently.

## Testing tools

- **Debug button**, on the researcher screen during a normal walk, reveals
  a small panel with live GPS accuracy, current waypoint number, distance
  to the next waypoint, latitude/longitude, whether the next waypoint is
  armed, whether the participant is inside the coarse wake region and inside
  the fire radius, whether a confirmation is part-way through, how stale the
  current fix is, how many waypoints have triggered, and which voice is in
  use. Hidden by default.

  **Fix age and GPS accuracy are the two readings to watch on a calibration
  walk.** Accuracy routinely worse than 25 m means the fire trigger is
  starving and prompts are falling through to backstops; a large fix age
  means prompts are landing late because iOS is batching updates.
- **Waypoint Test Mode**, toggled under **Modes** on the Home screen before
  starting a walk, replaces the normal researcher screen with a live map showing every
  waypoint, your current position, which waypoint is armed (orange), and
  which have already triggered (green) — useful for fine-tuning waypoint
  positions and radii before real data collection.
- **Waypoint preview cards.** Tapping a waypoint on any of the three maps
  opens a card with its number, radius, coordinates and script. The route
  overview and test mode show *both* conditions side by side for
  proof-reading; the active walk shows only the one that will actually be
  spoken. In the two-condition view the opening that the contextual script
  shares with the navigation prompt is dimmed, so the added context stands
  out — the scripts are alternatives, never played back to back.
- **Trigger radii are drawn to true scale** on all three maps. At the 10m
  radius every waypoint in both routes currently uses, they are sub-pixel
  until you zoom well in. That is deliberate: seeing their real size against
  the street is the point. The circle is the distance at which a prompt
  fires, so it is honest — the 100 m region CoreLocation actually monitors
  is not drawn, because it never fires anything.

## Recorded audio

`HomeView` runs on `RecordedAudioPromptPlayer` by default — real waypoint
recordings, not synthesised speech. It looks up `<id>_nav.mp3` /
`<id>_context.mp3` in `WayWalkResearch/Audio/RecordedWaypointAudio/` (a
folder reference, so a new MP3 dropped in there is picked up on the next
build with no project-file changes needed) and falls back to on-device TTS,
per prompt, for any file that isn't there yet. ~102 of the 110 possible
recordings exist today; the rest are still riding the fallback.

Both players implement the same `AudioPromptPlaying` protocol, so the
triggering logic, Home screen, and active-walk screen never know or care
which one is in use. To run on pure TTS instead — e.g. no recordings have
been made yet — change the one line in `HomeView`:

```swift
@StateObject private var session = WalkSession(audioPlayer: SpeechPromptPlayer())
```
