# StrideeHealth

Apple Health for the [Stridee developer platform](https://platform.stridee.com). Add it
to your iOS app and your users' Apple Watch and iPhone workouts, sleep, HRV and daily
activity reach your backend the same way Garmin, COROS or Polar data does: a webhook
event and an API call to fetch it. And the structured workouts your backend pushes with
`POST /v1/workouts` reach their Apple Watch.

HealthKit has no server API. The data exists only on the phone, so something has to
run inside your app to read it. This package is that something. It reads HealthKit,
queues what is new on disk, and uploads it to Stridee with a short-lived token your
server mints. Stridee turns each workout into a FIT file and normalizes the rest into
the same wellness records every other provider produces.

Full guide: **https://platform.stridee.com/docs/apple-health**

## Requirements

- iOS 17+
- The **HealthKit** capability, with **Background Delivery** checked
  (`com.apple.developer.healthkit.background-delivery`)
- `NSHealthShareUsageDescription` in `Info.plist`
- A server that can call `POST /v1/device-tokens` (see below)

## Install

Swift Package Manager, from `https://github.com/stridee-fit/stridee-health-ios`.

## Use

**1. On your server**, add a route your app calls to get a device token. Authenticate
your user however you already do, then make a signed request to Stridee:

```http
POST /v1/device-tokens
{ "external_user_id": "<your id for this user>" }

→ 201 { "token": "sdt_…", "user_id": "…", "expires_at": "…" }
```

The token lasts an hour and can only push this one user's data. It cannot read anything
they recorded — only the workouts you scheduled for their watch — which is what makes it
safe on a phone.

**2. At launch**, in `application(_:didFinishLaunchingWithOptions:)`, on every launch:

```swift
import StrideeHealth

HealthSync.configure(HealthSync.Configuration(
    tokenProvider: {
        let minted = try await MyAPI.strideeDeviceToken()   // your route from step 1
        return HealthSync.DeviceToken(token: minted.token, expiresAt: minted.expiresAt)
    }
))
```

It has to be there rather than in a view. HealthKit relaunches your app in the
background to deliver new data, and only reaches observers registered before launch
finishes.

**3. When the user opts in:**

```swift
try await HealthSync.shared.connect()
```

That shows the HealthKit permission sheet, connects the user (your webhook gets
`account.connected`), and starts syncing: the full workout history first, then each
new workout and night as HealthKit records it.

**4. For your settings screen:**

```swift
@ObservedObject var health = HealthSync.shared
// health.status: isConnected, isSyncing, lastSyncDate, lastError, pendingUploads, progress

try await health.syncNow()
await health.disconnect()                        // everywhere: account.disconnected
await health.disconnect(revokeOnServer: false)   // this device only, e.g. on sign-out
```

## Workouts on the watch

Apple has no server API for putting a workout on an Apple Watch; WorkoutKit, inside an
app, is the only way. Turn it on and the SDK schedules whatever your server pushes:

```swift
HealthSync.configure(HealthSync.Configuration(
    tokenProvider: { … },
    schedulesWorkouts: true
))

// When the user turns on "Send workouts to my Apple Watch" — shows iOS's sheet, once.
await HealthSync.shared.requestWorkoutSchedulingAuthorization()
```

Your server then calls `POST /v1/workouts` as it would for a Garmin. The `apple` push
comes back `pending`, and turns `synced` when the phone next syncs: on foreground, on a
HealthKit wake, or when you call it yourself —

```swift
try await HealthSync.shared.syncScheduledWorkouts()   // e.g. on a silent push from your server
HealthSync.shared.status.workoutScheduling            // authorization, scheduledCount, waitingCount, lastError
```

Edits replace the scheduled workout and deletes remove it. The Workout app holds a small
fixed number of scheduled workouts, so the nearest dates go on first and the rest wait
their turn. When the user does one, its `activity.created` carries `workout_id`.

## Permissions

Apple's permission sheet appears once per data type, ever. Ask well:

```swift
// A screen explaining what you read and why, before Apple's sheet.
// Continue connects; the words are yours (HealthAccessPrimer.Copy).
HealthAccessPrimer(onFinished: { … }, onNotNow: { … })

try await HealthSync.shared.requestAuthorization()   // ask without connecting
await HealthSync.shared.authorizationStatus()        // .unavailable / .notRequested / .requested
HealthSync.shared.status.lastDataFound               // [.workouts: Date, .wellness: Date]
await HealthSync.shared.openSettings()               // your app's page in Settings
```

iOS never says whether read access was *granted*. `.requested` means the user answered,
not that they said yes. `lastDataFound` is how you notice a "no": connected for days with
nothing found usually means the switches are off. Show `openSettings()`.

## Configuration

| | Default | |
|---|---|---|
| `tokenProvider` | required | Returns a fresh `DeviceToken` from your server |
| `dataTypes` | `[.workouts, .wellness]` | What to read and send |
| `excludedSourceBundleIDs` | Garmin Connect, Wahoo | Workouts those apps mirror into HealthKit are skipped, since they reach Stridee natively with richer files |
| `wellnessHistoryDays` | `90` | Wellness history sent on the first sync |
| `baseURL` | `https://api.stridee.com` | |
| `importWorkoutAnchorFromUserDefaultsKey` | `nil` | Resume from your own pre-SDK `HKQueryAnchor` instead of re-sending every workout |
| `schedulesWorkouts` | `false` | Schedule the workouts your server pushes on the Apple Watch |

## How it behaves

- **Nothing is lost.** Uploads are written to disk before they are sent and retried on
  the next sync. A failing token route, no network, or the app being killed all just
  delay them.
- **Workouts are sent once.** Each is keyed by its HealthKit UUID, on the phone and on
  the server.
- **Wellness is re-sent on purpose.** Every sync re-collects the last couple of days,
  because a watch writes yesterday late. Each item's identity is its kind and start
  time, so an unchanged item does nothing and a changed one becomes `wellness.updated`.
- **Daily totals are computed on the phone**, with HealthKit's statistics queries, which
  merge iPhone and Apple Watch without double counting the same steps.
- **Read access is invisible.** iOS never reveals whether the user granted it. The SDK
  can only tell you it asked, and whether data has arrived since.
- **Locked phones hold their data back.** HealthKit is unreadable until first unlock.
  The SDK catches up afterwards.
- **The watch mirrors your server.** Each sync makes WorkoutKit's schedule match what the
  API lists: only workouts the SDK scheduled are touched, never ones your app scheduled
  itself. Disconnecting takes them off.

## App Store

Health data may not be used for advertising (Guideline 5.1.3). Say in your privacy
policy and App Privacy labels that health data is sent to your backend through Stridee.

## Development

This repository is a read-only mirror of `sdk/ios/` in the Stridee monorepo, where the
API it talks to also lives. Tags here (`1.0.0`) come from `sdk-ios/v1.0.0` tags there.

```sh
xcodebuild test -scheme StrideeHealth -destination 'platform=iOS Simulator,name=iPhone 16'
```
