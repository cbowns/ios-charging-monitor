# ChargeSpeed (ios-charging-monitor)

Personal dev-only iPhone app: live charge power in watts from private APIs. Not App Store safe.

## Build and deploy

- XcodeGen project: `xcodegen generate` after editing `project.yml` or adding files.
- Scheme `ChargeSpeed`, bundle id `com.gregwilson.chargespeed`, team in `project.yml`.
- Runs on iPhone 17 Pro Max (iOS 26) and iPhone 18 Pro Max (iOS 27) with the same sensor names. `batteryWattHours` is still the 17 Pro Max value.
  Also runs on iPhone 14 Pro (iPhone15,2, iOS 27): 38 HID sensors instead of ~75, plus `Charger QQ0u`/`WQ0u`; headline `VQ0u × IQ0u` still matches.
- Deploy: `/deploy-to-iphone`. Console-attached launch (phone unlocked):
  `xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.gregwilson.chargespeed`
- Simulator runs but IOKit calls hit the Mac, so it shows the Mac's battery.
- Release IPA: `.github/workflows/release.yml` builds an unsigned IPA on any `v*` tag and attaches it to a
  GitHub release. To ship: bump `MARKETING_VERSION` in `project.yml`, `git tag vX.Y.Z && git push origin vX.Y.Z`.
  Keep it unsigned; a signed IPA embeds the team, certificate, and registered device UDIDs.

## Code

- `IOKitBattery.swift`: dlsym'd IOKit. `IOPMPowerSource` registry (sandbox leaves 2 keys on iOS), powerd `IOPSCopyPowerSourcesInfo`, `IOPSCopyExternalPowerAdapterDetails`, `IOPSCopyChargeStatus` (always refused).
- `HIDSensors.swift`: `IOHIDEventSystemClient`, usage page 0xff08 (usage 2 = A, 3 = V), 0xff00/5 = temps. One client per process; created once.
  Each sensor read costs ~1.1 ms (44 ms for all 38 on a 14 Pro), so never read them all on the main thread.
- `SensorSampler.swift`: owns the HID client on a background queue. Fast set (`VQ0u IQ0u IQ0B VQ0l VP0u VQ1u`) read at 10 Hz and averaged per 1 s window (min/max kept as `Reading.spread`, recorded as `rng`); the rest read round-robin, ~1 Hz each. Measured on 14 Pro: charger and `PMU tdie*` change faster than 15 Hz; `tdev*`, ALS, `TV*s` ~1 Hz; gas gauge battery temps < 0.1 Hz.
- `SensorRateProbe.swift`: "Measure sensor update rates" in Raw data; per-sensor read cost and single-sensor tight-loop change rates, run exclusively on the sampler queue. Report saved to Documents/sensor-rates-*.txt.
- `PowerSnapshot.swift`: merges sources. Headline = `Charger VQ0u × IQ0u` (USB-C input). `IQ0B × VQ0l` = into battery. `VQ1u` = wireless coil rail voltage (MagSafe ≈14 V, Qi BPP pad ≈10 V; adapter description "magsafe chg" vs "baseline arcas") (no wireless input current sensor exists, so MagSafe input watts are unavailable; headline falls back to battery watts). `gas gauge battery` (several; app shows the max), `Charger TQ0j`, `PMU tdie*` = temps. Throttling flag = `ProcessInfo.thermalState` serious/critical; battery colored ≥38 °C amber, ≥42 °C red.
- `PowerMonitor.swift`: 1 s poll, %-rate fallback (`batteryWattHours` = 19.7 for 17 Pro Max), hold detection with 45 s debounce, peak of the headline watts per charging session (median of last 3 samples; resets at plug-in, survives full/top-off and relaunch via persisted session identity: adapter serial + last-seen plugged/percent; manual reset button).
- `PowerMonitor.ingest(snapshot, ambient)` holds all per-tick logic; live polling and replay both feed it. A replay monitor (`PowerMonitor.forReplay()`) has no hardware readers and persists nothing. Only one `HIDSensors` exists (static).
- `Recording.swift`: JSONL recorder in Documents/Recordings (Files-app visible), one file per launch, 12 h rollover. Dicts and the sensor catalog are written only on change; ticks carry sensor values in catalog order plus thermal state, brightness, dark mode, app state. `Recording` parses a file for replay.
- `ChargeEvents.swift`: `EventDetector` derives plug/unplug, adapter, profile, status (debounced), thermal state, battery 38/42 °C crossings, brightness, appearance. Events are also written to the recording.
- `Replay.swift`: recordings list, `ReplayController` (play, speed, scrub; seeking backwards rebuilds the monitor), replay reuses `ContentView`.
- `SmartCharge.m`: PowerUI client, blocked on iOS, kept for macOS/entitled builds. `Probes*.swift/.m`: DEBUG exploration only, not called.

## Verified blocked on iOS 26 and 27 (don't retry)

IOKit battery registry keys beyond `BatteryInstalled`/`ExternalConnected`; `IOReport`; `IOPMCopyBatteryInfo`;
`IOPSCopyChargeStatus`, `IOPSCopyBatteryLevelLimits`, `IOPSCopyPowerSourcesInfoPrecise` (all kIOReturnNotPrivileged);
PowerUI XPC (Optimized Charging / charge limit settings); CFPreferences of other domains; powerd `Time to Empty` (always 0);
any discharge-current sensor (none exists in the 75 HID services). Darwin notify `smartchargestatuschanged` state is always 0.
