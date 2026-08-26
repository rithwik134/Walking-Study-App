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
  Models/                        ← Waypoint, Walk, InformationLevel, SessionEvent, RoutePath
  Data/
    RouteDataStore.swift         ← loads route JSON from the app bundle
    walkA.json, walkB.json       ← sample route data — replace with your real route
    walkA_path.json, walkB_path.json ← precomputed walking paths (see "Routed map lines")
    RoutePathStore.swift         ← loads the precomputed paths
    SessionLogger.swift          ← writes one CSV per walk, as it happens
    SessionStore.swift           ← lists/deletes past session files
  Audio/
    AudioPromptPlaying.swift     ← protocol
    SpeechPromptPlayer.swift     ← speech synthesis (used today)
    RecordedAudioPromptPlayer.swift ← drop-in replacement once you have recordings
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
event_index, event_type, time_iso, time_local, elapsed_s, region_entry_local,
waypoint_order, waypoint_id, waypoint_name, trigger_source, latitude,
longitude, gps_accuracy_m, note`.

Two timing details worth knowing:

- **`time_local` is bare `HH:MM:SS`** in the device's timezone, so waypoint
  rows paste directly into the `Zone,In,Out` file the WayWalk Analyser
  expects. `time_iso` carries the full date and UTC offset for the archive.
- **`region_entry_local` vs `time_local`.** A prompt does not play the
  instant the geofence is entered — arrival is held for two seconds first.
  `region_entry_local` is when CoreLocation reported arrival;
  `time_local` is when the prompt started. Pick whichever matches how you
  are segmenting the physiological data.

### Forced prompts are marked

Every walk screen has a green **Play waypoint n** button. It is a failsafe: if
a geofence does not fire, the walk would otherwise stall there forever, since
the next waypoint is only armed once the current one fires. Pressing it plays
the instruction the participant was owed and unblocks the rest of the route.

Those rows carry `trigger_source = manual`; ones the participant's own arrival
produced carry `geofence`. **This distinction matters for analysis** — a forced
prompt is not evidence the participant was at that waypoint, and may mean they
were nowhere near it. Filter or annotate accordingly.

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

Pressing plays the current waypoint and advances to the next one, so the walk
progresses at the researcher's pace rather than the geofence's. Pressing again
before the previous prompt has finished **queues** the new one rather than
cutting it off.

For analysis, a manual row uses the two time columns to mean different things:

- `region_entry_local` — when CoreLocation reported arrival at the radius
  (empty if the prompt was played before arriving)
- `time_local` — when the button was actually pressed

**The gap between them is how long the researcher waited before cueing**, which
is the measurement this mode exists to produce.

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
pair of waypoints in turn (16 requests for a 17-waypoint route, deliberately
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
- **Trigger radii are drawn to true scale** on all three maps. At the radii
  currently in the route data (mostly 5m) they are sub-pixel until you zoom
  well in. That is deliberate: seeing their real size against the street is
  the point, and 5m is well below the GPS noise floor (see Known iOS
  constraints, and `Waypoint.swift`, which advises 20m or more).

## Swapping in recorded audio later

Add files named to match each waypoint (e.g. `a2_nav.mp3`,
`a2_context.mp3`) to the app bundle, then change one line in `HomeView`:

```swift
@StateObject private var session = WalkSession(audioPlayer: RecordedAudioPromptPlayer())
```

Nothing else changes — the triggering logic, Home screen, and active-walk
screen all depend only on the `AudioPromptPlaying` protocol, not on speech
synthesis specifically.
