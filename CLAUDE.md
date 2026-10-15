# ChargeSpeed (ios-charging-monitor)

Personal dev-only iPhone app: live charge power in watts from private APIs. Not App Store safe.

## Build and deploy

- XcodeGen project: `xcodegen generate` after editing `project.yml` or adding files.
- Scheme `ChargeSpeed`, bundle id `com.gregwilson.chargespeed`. Team: `Signing.xcconfig` (default), overridden by gitignored `Local.xcconfig` (`DEVELOPMENT_TEAM = …`). Don't set the team in `project.yml` or Xcode; `xcodegen generate` would reset it.
- Runs on iPhone 17 Pro Max (iOS 26) and iPhone 18 Pro Max (iOS 27) with the same sensor names.
  Also runs on iPhone 14 Pro (iPhone15,2, iOS 27): 38 HID sensors instead of ~75, plus `Charger QQ0u`/`WQ0u`; headline `VQ0u × IQ0u` still matches, but `Charger VQ0l` is not the battery (~3.25 V), `PMU VP0u` is.
- `DeviceProfile.swift`: per-model battery Wh and battery-voltage sensor order (14 Pro: 12.38 Wh, `VP0u` first). Unknown models (incl. 18 Pro Max) get the 17 Pro Max values.
- Deploy: `/deploy-to-iphone`. Console-attached launch (phone unlocked):
  `xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.gregwilson.chargespeed`
- Simulator runs but IOKit calls hit the Mac, so it shows the Mac's battery.
- `ChargeSpeed/Info.plist` is written by `xcodegen generate` from `info:` in `project.yml` (background modes); everything else comes from `INFOPLIST_KEY_*` settings.
- Build identity: a post-build script in `project.yml` stamps `GitCommit` (short hash, "-dirty" if uncommitted) and `BuildDate` into the built Info.plist; `BuildInfo.swift` shows them in the main list's footer, Copy raw, and recording headers. `MARKETING_VERSION` is still 0.1.0, so the commit is what identifies a build.
- Release IPA: `.github/workflows/release.yml` builds an unsigned IPA on any `v*` tag and attaches it to a
  GitHub release. To ship: bump `MARKETING_VERSION` in `project.yml`, `git tag vX.Y.Z && git push origin vX.Y.Z`.
  Keep it unsigned; a signed IPA embeds the team, certificate, and registered device UDIDs.

## Code

- `IOKitBattery.swift`: dlsym'd IOKit. `IOPMPowerSource` registry (sandbox leaves 2 keys on iOS), powerd `IOPSCopyPowerSourcesInfo`, `IOPSCopyExternalPowerAdapterDetails`, `IOPSCopyChargeStatus` (always refused).
- `HIDSensors.swift`: `IOHIDEventSystemClient`, usage page 0xff08 (usage 2 = A, 3 = V), 0xff00/5 = temps. One client per process; created once.
  Each sensor read costs ~1.1 ms (44 ms for all 38 on a 14 Pro), so never read them all on the main thread.
- `SensorSampler.swift`: owns the HID client on a background queue. Fast set (`VQ0u IQ0u IQ0B VQ0l VP0u VQ1u`) read at 10 Hz and averaged per 1 s window (min/max kept as `Reading.spread`, recorded as `rng`); the rest read round-robin, ~1 Hz each. Measured on 14 Pro: charger and `PMU tdie*` change faster than 15 Hz; `tdev*`, ALS, `TV*s` ~1 Hz; gas gauge battery temps < 0.1 Hz.
- `PowerSnapshot.swift`: merges sources. Headline = `Charger VQ0u × IQ0u` (USB-C input). `IQ0B × VQ0l` = into battery. `VQ1u` = wireless coil rail voltage (MagSafe ≈14 V, Qi BPP pad ≈10 V; adapter description "magsafe chg" vs "baseline arcas") (no wireless input current sensor exists, so MagSafe input watts are unavailable; headline falls back to battery watts). `gas gauge battery` (several; app shows the max), `Charger TQ0j`, `PMU tdie*` = temps. Throttling flag = `ProcessInfo.thermalState` serious/critical; battery colored ≥38 °C amber, ≥42 °C red.
- `PowerMonitor.swift`: 1 s poll (powerd/registry reads and the sensor window gathered on a background queue; brightness cached from its change notification; recorder writes on its own queue — keep the main thread to UI), %-rate fallback (`batteryWattHours` from `DeviceProfile`), hold detection with 45 s debounce, `seenProfiles` (every profile the attached adapter has reported, with time in each; shown as "Profiles seen" for wireless/menu-less adapters), peak of the headline watts per charging session (median of last 3 samples; resets at plug-in, survives full/top-off and relaunch via persisted session identity: adapter serial + last-seen plugged/percent; manual reset button).
- `PowerMonitor` sends `objectWillChange` itself (a `PassthroughSubject`, so `@Published` writes notify nothing): once at the end of `refresh`/`ingest`, from `resetPeak` and smart-charge updates, and never in the background. A new state change outside those needs `publish()`, or it shows up on the next tick.
- `BackgroundKeepalive.swift`: continuous `CLLocationManager` updates (3 km accuracy, pausing off, fixes discarded) keep the app running in the background and while locked; setting `backgroundRecording`, on by default; `BackgroundRecordingSection` shows it under the headline. While it runs, `ContentView` keeps the monitor polling at 1 Hz on `.background`, with the sampler at 2 Hz and UI updates off. "While Using" permission is enough because updates start in the foreground.
- Background, measured on 14 Pro (iOS 27), locked (protected data unavailable): all HID sensors, powerd source and adapter details, and the recorder (files are `CompleteUntilFirstUserAuthentication`) keep working. App CPU in the background: 4.7 % of a core as it was (10 Hz, hidden SwiftUI list re-rendering every second was ~3 %), 0.4 % now.
- Live Activity: `ChargeSpeedWidgets` extension target (`com.gregwilson.chargespeed.widgets`, Lock Screen + Dynamic Island) draws `Shared/ChargeActivityAttributes.swift`; `LiveActivityController.swift` (live monitor only, called from `refresh`) starts it while plugged in, updates at most every 5 s when the rounded shown values change (% or status at once), stale after 60 s without an update, ends at unplug, adopts the previous launch's activity, and leaves a swiped-away one alone until the next plug-in. Verified on 14 Pro (iOS 27.2): locked updates every ~5 s reach the Lock Screen, end at unplug works. Starting from the background is refused (`ActivityAuthorizationError.visibility`) even with the keepalive running, so a locked plug-in starts it at the next foreground; only push-to-start (APNs) would avoid that.
- `PowerMonitor.ingest(snapshot, ambient)` holds all per-tick logic; live polling and replay both feed it. A replay monitor (`PowerMonitor.forReplay()`) has no hardware readers and persists nothing. Only one `HIDSensors` exists (static).
- `Recording.swift`: JSONL recorder in Documents/Recordings (Files-app visible), one file per launch, 12 h rollover. Dicts and the sensor catalog are written only on change; ticks carry sensor values in catalog order plus thermal state, brightness, dark mode, app state. `Recording` parses a file for replay.
- `ChargeEvents.swift`: `EventDetector` derives plug/unplug, adapter, profile, status (debounced), thermal state, battery 38/42 °C crossings, brightness, appearance. Events are also written to the recording.
- `Replay.swift`: recordings list, `ReplayController` (play, speed, scrub; seeking backwards rebuilds the monitor), replay reuses `ContentView`.
- Adapter details on iOS (`IOPSCopyExternalPowerAdapterDetails`): Description ("pd charger", "usb charger", "usb type-c", "magsafe chg"), FamilyCode, AdapterVoltage, Current, Watts, AdapterPowerTier, UsbHvcMenu/UsbHvcHvcIndex (PD only), Source/ErrorFlags (wireless). No manufacturer, model or real serial; `SerialString` appears only sometimes, as "UNKNOWN". `UsbHvcHvcIndex` lags (stuck at 0 = 5 V while AdapterVoltage and the measured input said 9 V), so the contract is AdapterVoltage × Current. Plug-in reports "usb charger" 5 V × 1.5 A for ~1 s before the real adapter; unplug reports a 0 W / 0 A placeholder for one tick. Some chargers re-advertise a different PD menu mid-session, with a ~5–10 s drop to 5 V / ~0 A each time.
- `MetricChart.swift`: tappable rows (into-battery watts, battery voltage, battery temp, SoC hottest die) open a fixed, non-scrolling chart of the last 2/5/15 min from `PowerMonitor.series` (15 min kept; min/max band from `spread`; event rules; minimum y span per metric). A scrollable version was choppy: it rebuilt every mark on each scroll frame.
- `ThermalPressure.swift`: notify state `com.apple.system.thermalpressurelevel` is readable on iOS 27 (0 nominal … 4 sleeping, finer than `ProcessInfo.thermalState`); recorded per tick as `tp`, shown under Thermals, changes logged as thermal events.
- HID matching on an empty dictionary returns 0 services on iOS; always match a specific PrimaryUsagePage (and usage). Visible on 14 Pro: 0xff00/3 accel, /4 als, /5 temps (27), /8 prox, /9 gyro, /10 compass; 0xff08 power (11); 0x20 orientation, pressure.
- Ambient light "als" (0xff00/4, event type 12) is readable: field 0 lux, 1-4 raw channels, 6 colour space, 7-9 CIE XYZ (Y = lux), 10 colour temperature (K), 11 lux as float. Recorded as sensors "als" (usage 4) and "als cct" (pseudo-usage 0x10004). An LED flashlight read 14,564 lux with the top raw channel at 508,680 (near 2^19), so check for saturation in direct sun. Sun events: enter ≥ 20,000 lux, leave < 10,000, 5 s each.
- `SmartCharge.m`: PowerUI client, blocked on iOS, kept for macOS/entitled builds. `Probes*.swift/.m`: DEBUG exploration only, not called.

## Verified blocked on iOS 26 and 27 (don't retry)

IOKit battery registry keys beyond `BatteryInstalled`/`ExternalConnected`; `IOReport`; `IOPMCopyBatteryInfo`;
`IOPSCopyChargeStatus`, `IOPSCopyBatteryLevelLimits`, `IOPSCopyPowerSourcesInfoPrecise` (all kIOReturnNotPrivileged);
PowerUI XPC (Optimized Charging / charge limit settings); CFPreferences of other domains; powerd `Time to Empty` (always 0);
any discharge-current sensor (none exists in the 75 HID services). Darwin notify `smartchargestatuschanged` state is always 0.
