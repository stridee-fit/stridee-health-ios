# Changelog

Each version's section here becomes its GitHub Release, word for word, when it is tagged.
Write the section in the same change that is released as it: a tag with no section here
publishes no release, and the release workflow fails to say so.

## 1.2.1 — Releases from CI

No changes to the package. GitHub Releases are now published by CI from this file, rather
than by hand.

## 1.2.0 — GPS workout recording

Record runs, rides, walks and hikes on the iPhone with `WorkoutRecorder`. Your app draws the
screens; the SDK does the recording and delivers it — saved to Apple Health with its route,
and uploaded to Stridee as the same `activity.created` and FIT file an Apple Watch workout
becomes.

```swift
let recorder = WorkoutRecorder.shared
await recorder.requestAuthorization()     // location, then Apple Health
try recorder.start(.running)
recorder.pause(); recorder.resume()
let workout = try await recorder.finish()
```

- **Live state for your UI**: `state`, `metrics` (distance, moving time, current and average
  pace, elevation gain), `route`, `gpsAccuracy`, `laps`, `currentSection`, `heartRate`.
- **Clean GPS**: inaccurate fixes, GPS resets and drift while standing still are not
  distance. Elevation comes from the barometer when `NSMotionUsageDescription` is set.
- **Auto-pause**, tuned per activity.
- **Auto-laps** every 1 km on foot and every 5 km on a bike, or at `lapDistance`.
- **Structured workouts**: pass `sections:` and the recorder follows each step's distance or
  time.
- **Pace cues** against a `targetPace` or a section's own target: behind, ahead, back on
  target — patient, and never nagging.
- **`onEvent`** for a voice coach, haptics or a live view: every GPS sample, laps, section
  changes, pace cues, auto-pause.
- **Crash-safe**: every fix is on disk as it arrives, and a recording interrupted by a crash
  or a force-quit comes back paused (`wasRecovered`).
- **Uploads connected or not**: recording counts as consent, so a finished workout goes to
  `POST /v1/device/apple/recordings` even for a user who never turned on Apple Health sync
  (it connects them; `account.connected` the first time). Offline, it waits on disk.
- **Sent once**: the Apple Health sync skips a workout the recorder already uploaded.
- `uploadsToStridee: false` hands the route, heart rate and laps back on `FinishedWorkout`
  for apps that send recordings themselves.

### Bluetooth heart-rate straps

`HeartRateMonitor.shared` scans for, connects to and remembers any standard Bluetooth LE
strap (Polar, Wahoo, Garmin, COROS…). While recording, its readings go into the workout on
their own. Needs `NSBluetoothAlwaysUsageDescription`; Bluetooth is never touched until you
call `startScan()` or a strap was paired before.

### Also

- `HealthSync.disconnect()` no longer drops a recording still waiting to upload.

### Info.plist

| Key | |
|---|---|
| `NSLocationWhenInUseUsageDescription` | Required to record |
| `UIBackgroundModes` → `location` | Keeps recording with the screen locked |
| `NSHealthUpdateUsageDescription` | To save recordings to Apple Health |
| `NSMotionUsageDescription` | Optional, for barometric elevation |
| `NSBluetoothAlwaysUsageDescription` | Optional, for heart-rate straps |

No breaking changes: everything in 1.1.0 works as before.
