# Follow-up 1: Can FreeBee capture (and process) in the background all day on iOS 27.0.1? Live pipeline vs. capture-then-batch

Scope note: this session found no measurement of a BLE audio wearable app on iOS 27 that answers the core question. The sources here are Apple primary sources (TN3115, iOS 27 release notes, the local iOS 27.1 SDK, DTS forum replies), Omi's 2026 field telemetry (the only detailed public iOS data for an always-on BLE audio pendant), and our own code and captures. Three findings matter most and are new relative to the earlier notes:
1. **iOS 27 restricts background Neural Engine access.** Apple's iOS 27 release notes say a backgrounded app needs a new entitlement to use the ANE. That directly undercuts the "Parakeet in the BLE-kept-alive background" plan.
2. **Apple staff confirmed the iPhone 17 Pro runs "AFM 3 Core Advanced 20B" on iOS 27.0, and `SystemLanguageModel.variant` reports the tier.** The "no API to tell the tier" premise is wrong.
3. **FreeBee's iOS audio path is not implemented yet.** `BeeKit` contains the audio characteristic UUID (only in `Sources/BeeProtocol/Protocol.swift`), but no decrypt or ADTS code was found in `BeeKit/Sources` or the app target. So every "all-day background capture" number on iOS is still hypothetical. The 8–16 h test can only run after that path exists.

## Q1. 8–16 h locked/in-pocket test on iPhone 17 Pro / iOS 27.0.1: does FreeBee keep receiving ~8 notifications/s without suspension or throttling?

### Takeaway
No one has run this test, and no public source reports it for iOS 26/27 with a `bluetooth-central`-only app. The best field evidence is Omi's (iOS 26.6). It shows iOS will keep a connected BLE-pendant app executing for 16 h in the background without CPU-monitor kills. Omi's failures came from link drops (`connection_timeout` at RSSI −91 to −97), reconnect storms, a jetsam kill at about 637 MB resident, and stacked keep-alives (an audio session among them). So the stream itself is unlikely to be throttled. Disconnects, memory and any extra side work are what break it. iOS 27 adds new MetricKit types (`BackgroundTerminationMetric`, `MemoryExceptionDiagnostic`) that make this test cheap to instrument, but the audio path has to be built first.

### Cited Findings
- **FreeBee's current state (local code):**
  - The iOS app has `bluetooth-central` as its only background mode — `Support/Bee-AccessorySetupKit.plist` (local).
  - It uses a constant restore identifier, `BeeCentral(restoreIdentifier: "bee.central")` — `FreeBee/Model/BeeStore.swift:442` (local).
  - It stores the SKV1 token with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a locked-phone reconnect can read it — `FreeBee/Model/KeyStore.swift:24` (local).
  - It polls RSSI every 4 s, gated by `isActive` — `FreeBee/Model/BeeStore.swift:744-752` (local).
  - It reads `maximumWriteValueLength(for: .withoutResponse)` only to bound SMP writes, and does not log it — `BeeKit/Sources/BeeKit/BluetoothTransport.swift:86` (local).
  - No AES-CTR or ADTS code was found in `BeeKit/Sources` or the app target (grep for `CCCrypt`, `kCCModeCTR` and the audio UUID found only `BeeProtocol/Protocol.swift`).
- **Omi field telemetry (iPhone 15 Pro Max, iOS 26.6, CV1 fw 3.0.21, pocket carry):**
  - iOS Battery showed "51% attributed to Omi, 4m on screen / 16h 19m background".
  - 19/20 recent disconnects were `connection_timeout` (CBError 6) with `appState=background` at RSSI −91 to −97.
  - There were reconnect retries every 1–2 s, and one ~4.9 h connection that then timed out at −93.
  - Lifetime counts were 983 reconnects and 137 failed connects.
  - A live Power Profiler attach showed the process "still retired ~150–300M CPU instructions/s" in the background.
  - — [BasedHardware/omi #11307, comment 2026-08-13](https://github.com/BasedHardware/omi/issues/11307)
- **Omi jetsam and disk-write reports (same device, 2026-08-12/13):**
  - Jetsam: `largestProcess = Runner`, process **active (not suspended)**, ~637 MB resident, lifetime max ~947 MB, `freeze_skip_reason: out-of-slots`.
  - Disk writes: `diskwrites_resource` report of "1074 MB dirtied over 19199s (55.96 KB/s, limit 12.43 KB/s)", 61/83 samples non-frontmost.
  - Omi attributes the 51% to "preventing suspend + radio + audio, not Dart burning a core" (coalition energy 38.15 mWh CPU-side).
  - — [omi #11307](https://github.com/BasedHardware/omi/issues/11307)
- **Omi's keep-alives were stacked and confounded:** `UIBackgroundModes` includes `audio`, a held `AVAudioSession` (green mic indicator), a foreground task started whenever location permission exists, a 5 s battery-characteristic poll, and a 200 ms reconnect with no backoff — [omi #11307](https://github.com/BasedHardware/omi/issues/11307). Omi's maintainers state that "no phone energy has ever been measured" for their background fixes (opened 2026-09-28) — [omi #19565](https://github.com/BasedHardware/omi/issues/19565).
- **A pendant-side failure can look like a phone-side one:** in an Omi factory-control trace (~10.5 h), there were 12 connects and 11 disconnects. After one hardware AAD sleep the mic never woke again ("1 AAD sleep and 0 AAD wakes"), so reconnects did not restore capture — [omi #11307, comment 2026-08-14](https://github.com/BasedHardware/omi/issues/11307). By analogy, Bee state 2/4 (sleep with VAD) could stall the stream with the link still up.
- **DTS testing advice for background relaunch (Kevin Elliott, Aug 2026):**
  - Enable Developer → "Fast App Termination" to "simulate 'natural' process death".
  - Post a local notification "as early as possible (typically in applicationDidFinishLaunching) without any Bluetooth check".
  - Use a constant restore identifier, because "a non-constant value can end up generating the problem you're seeing".
  - — [Apple Developer Forums 840468](https://developer.apple.com/forums/thread/840468)
- **DTS on background scanning vs. connected use:** "CBCentralManagerScanOptionAllowDuplicatesKey … is ignored, and multiple discoveries … are coalesced" in the background. The fix is "for your app to connect with your accessory and directly interact with it instead of trying to rely on passive scanning" — [forums 840468](https://developer.apple.com/forums/thread/840468)
- **iOS 26/27 BLE regressions reported in 2026 (all developer reports):**
  - Disconnects ~30 s after reconnect after upgrading 26.2 → 26.4 (CBError 7) — [forums 838566](https://developer.apple.com/forums/thread/838566)
  - Advertise/scan sessions interrupted on backgrounding on iPhone 17 — [forums 815922](https://developer.apple.com/forums/thread/815922)
  - Encryption failures after upgrading to iOS 27 (CBError 15) — [forums 834060](https://developer.apple.com/forums/thread/834060)
  - Disconnects during writes on the iOS 27 public beta — [forums 839288](https://developer.apple.com/forums/thread/839288)
  - None of these is a connected-notify streaming case like ours.
- **iOS 27 MetricKit (primary):**
  - The new Swift-first `MetricManager` delivers `MetricReport`/`DiagnosticReport` via `AsyncStream`. `MetricReport` "contains a daily aggregated entry along with interval-based breakdowns that are typically a few hours each".
  - `MemoryExceptionDiagnostic` is new and is delivered "when your app … is terminated for exceeding its memory limit".
  - `CrashDiagnostic` gains `terminationCategory`.
  - The original `MXMetricManager`/`MXDiagnosticPayload` APIs "are no longer recommended for new adoption".
  - — [iOS & iPadOS 27 release notes, MetricKit](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) (read via the docs JSON endpoint)
- **iOS 27.1 SDK MetricKit types (local `MetricKit.swiftinterface`):**
  - `BackgroundTerminationMetric` has `memoryLimitTerminationCount`, `highCPUTerminationCount`, `systemPressureTerminationCount`, `watchdogTerminationCount`, `fileLockTerminationCount` and `taskTimeoutTerminationCount`.
  - Diagnostics include `cpuException(CPUExceptionDiagnostic)` (with `totalCPUTime` and `totalSampledTime`), `diskWriteException` and `memoryException`.
  - Metrics include `totalBackgroundTime`, `cpuTime`, `cpuInstructionsCount`, `peakMemory`, `suspendedMemory` and `logicalDiskWrites`.
  - The legacy ObjC `MXAppExitMetric.h` still exposes `cumulativeCPUResourceLimitExitCount` and `cumulativeBackgroundTaskAssertionTimeoutExitCount`.
  - — iPhoneOS27.1.sdk `MetricKit.framework` (local)

### Inferences
- **What to expect:** the evidence suggests a connected, subscribed `bluetooth-central` app receiving ~8 notifications/s will keep being scheduled while locked. Omi ran 16 h in the background, and the iOS 26 DTS guidance treats a connected link as the supported way to get repeated work. Omi's audio session confounds the comparison, so the `bluetooth-central`-only case is still unproven on iOS 27.0.1. The likely failure modes, in order:
  1. Link supervision timeouts at weak RSSI, with the phone in a pocket and the Bee on the other side of the body.
  2. Session-reopen failures after reconnect. The nonce is per session, so every reconnect needs SetEncryptionKey → GetSessionNonce → re-subscribe.
  3. Jetsam if the background footprint grows (models loaded, buffers).
  4. A device-side stall (Bee in a VAD-sleep state) while the link is still up.
- **Suggested test harness** (build after the audio path exists):
  - **Per notification**, append a compact binary or JSONL record: wall-clock ns, `seq`, byte count, decrypted-ADTS-syncword OK, and frames emitted. Flush in batches (for example every 10 s) to limit disk writes.
  - **Per link event**, log: disconnect reason (CBError code), RSSI at the last read, the time from disconnect to `didConnect`, then to the session nonce, then to the first notification, then to the first valid ADTS frame. Also log app state (`UIApplication.applicationState`) and protected-data availability.
  - **Per launch**, log the launch reason (`UIApplication.LaunchOptionsKey.bluetoothCentrals`), the `willRestoreState` dictionary keys, and an ungated local notification, per DTS. Read the previous run's tail on launch to detect silent kills: a gap in the log with no disconnect event points to suspension or jetsam.
  - **Subscribe to `MetricManager`** and persist every `DiagnosticReport`, plus the `BackgroundTerminationMetric` counts, especially `highCPUTerminationCount`, `memoryLimitTerminationCount` and `systemPressureTerminationCount`. Reports arrive aggregated over hours to a day, so they confirm what the app's own log suggests and do not replace it.
  - **Also collect** the raw `.ips` reports from Settings → Privacy & Security → Analytics Data (`JetsamEvent`, `cpu_resource`, `diskwrites_resource`), as Omi did. Use Xcode Organizer energy logs only for TestFlight/App Store builds.
  - **Run variants:** (a) muted Bee (state 0) with the link up, as a control; (b) recording, capture-only; (c) capture plus VAD; (d) capture plus live ASR. Each needs at least one full day, screen locked, in a pocket, with the Bee worn.
  - Keep the 4 s RSSI poll gated to the foreground. Omi's 5 s battery poll and 3 s RSSI poll were flagged as battery consumers ([omi #19565](https://github.com/BasedHardware/omi/issues/19565)). Read RSSI only when a disconnect seems imminent, or once a minute in the background, for the disconnect study.

### Gaps
- No iOS 27 measurement of a `bluetooth-central`-only app streaming continuously for hours exists in any source found. Omi's data is from iOS 26.6 and includes an `audio` keep-alive.
- No Apple statement on whether a continuously notifying connection is ever deprioritised (for example, notifications coalesced while locked). Only measuring inter-arrival times while locked will show this.
- No public data on Bee firmware 0.6.1 behaviour in states 2/4 (VAD sleep) during long sessions. The device could stop sending while the link stays up.

## Q2. Sustained CPU of the always-on path, closeness to the CPU monitor, and whether adding Parakeet/SpeechTranscriber gets the app killed

### Takeaway
The light path (AES-CTR, ADTS reassembly, AAC decode, Silero VAD) should cost low single-digit percent of one core. That is an estimate from component specs; none of it has been measured on the A19 Pro. It sits far below the "80% over 60 s" monitor. The bigger news is that **iOS 27 restricts background Neural Engine access**: a backgrounded app needs `com.apple.developer.background-tasks.continued-processing.inference`. A BLE-kept-alive app without it cannot count on the ANE for Parakeet. Falling back to CPU could approach the CPU-monitor thresholds and the memory limit. So "Parakeet batches in the BLE wake path" is not a safe design on iOS 27.0.1 until it is tested with and without that entitlement.

### Cited Findings
- **iOS 27 Neural Engine background restriction (primary, Core AI section):** "The system now restricts background access to the Neural Engine, similar to GPU usage restrictions … Neural Engine memory usage is now attributed to your app process instead of the system, and appears in the Allocations instrument. (174796039) Access to the Neural engine when your app is in the background requires the new entitlement: 'com.apple.developer.background-tasks.continued-processing.inference'. (179282606)" — [iOS & iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- **History of that note:** in an earlier iOS 27 beta it read "You cannot access the Neural Engine when your app is in the background. Workaround: Restrict your models to CPU only or prefer GPU with the appropriate Background GPU Access entitlement". Beta 3 replaced it with the entitlement requirement — [release-notes diff gist (beta 3)](https://gist.github.com/galenguyer/eef52cf39cbb7745fe98f2e32f453590). A developer had earlier reported that "in iOS 26, Core ML reliably submits inference requests targeting the Neural Engine in the background" but that it was broken in iOS 27 seed 1 — [forums 832048](https://developer.apple.com/forums/thread/832048)
- **The iOS 27.1 SDK headers only show the GPU entitlement:** `BGContinuedProcessingTaskRequestResources` contains only `.gpu`, which requires `com.apple.developer.background-tasks.continued-processing.gpu`. No `.inference` resource flag or header mention exists — iPhoneOS27.1.sdk `BackgroundTasks.framework/Headers/BGTaskRequest.h` lines 116–153 (local). A grep of Xcode 27.1's SharedFrameworks/PlugIns found no "continued-processing" capability strings either.
- **Background GPU is not available on iPhone:** DTS (Kevin Elliott, Nov 2025) says background GPU "won't help on the iPhone (it's not available there)" — [forums 807957](https://developer.apple.com/forums/thread/807957) (from the earlier note on_device_speech_audio_ml.md)
- **Foundation Models in the background is best-effort:** "The OS manages the requests for the on-device LLM automatically, based on the system conditions (like thermals). There's no entitlement or API to influence this." — Apple Frameworks Engineer, June 2026, [forums 833666](https://developer.apple.com/forums/thread/833666). "Excessive requests to the model made in the background might be throttled or canceled" — Apple Frameworks Engineer, June 2026, [forums 833642](https://developer.apple.com/forums/thread/833642) (via the earlier note)
- **CPU monitor thresholds (all from crash logs, none documented):**
  - "48 seconds cpu time over 55 seconds (87% cpu average), exceeding limit of 80% cpu over 60 seconds", with the process killed, even inside a BGProcessingTask — [forums 690666](https://developer.apple.com/forums/thread/690666). The archived energy guide also shows "(Limit 80%) Observed 89% over 60 seconds" — [Energy Efficiency Guide (archived)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html)
  - The **50% variant exists**: crash logs read "90 seconds cpu time over 179 seconds (50% cpu average), exceeding limit of 50% cpu over 180 seconds" and "(Limit 50%) Observed 58% over 180 secs". In that thread a developer was killed "in the foreground repeatedly" during user-initiated work, and worked around it by pausing a queue for 5 s every 2 min — [forums 123975](https://developer.apple.com/forums/thread/123975) (from search-result excerpts; the thread is older and its iOS version was not checked).
  - A "60% over 15 seconds" background limit is mentioned in another thread, where a responder advised that limits are "a hard limit that your app shouldn't be getting anywhere near" — search-result summary only, thread not identified. Treat as unverified.
- **The CPU monitor can be disabled on power:** `BGProcessingTaskRequest.requiresExternalPower = YES` "will also disable the CPU Monitor feature" — iPhoneOS27.1.sdk `BGTaskRequest.h` (local; via ios_ble_background_streaming.md)
- **Silero VAD cost:** "One audio chunk (30+ ms) takes less than 1ms to be processed on a single CPU thread". Supports 8 kHz and 16 kHz; the JIT model is about 2 MB — [snakers4/silero-vad README](https://github.com/snakers4/silero-vad)
- **Parakeet throughput on an older iOS device:** Parakeet TDT v3 via FluidAudio (Core ML, ~600 MB) reached 181.8 output words/s on an iPad Pro 3rd gen (A12X, 4 GB), on a 30 s looped-JFK clip. WhisperKit Base/Small/Large v3 Turbo ran out of memory on that 4 GB device. No RTF, peak memory, compute units, background or battery data was reported — [VoicePing offline STT benchmark (updated 2026-09-21)](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/)
- **Memory headroom matters in the background:** Omi was jetsammed as `largestProcess` at ~637 MB resident while active in the background — [omi #11307](https://github.com/BasedHardware/omi/issues/11307). From iOS 27 on, ANE model memory is charged to the app process ([iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)). A ~600 MB Parakeet Core ML model therefore now counts fully against FreeBee's background footprint.

### Inferences
- **Light-path CPU budget:** at 16 kHz with 512-sample (32 ms) Silero hops there are ~31 inferences/s. At under 1 ms each (reference CPU unspecified), that is under ~3% of one core, and probably well under on A19 Pro P/E cores. AES-128-CTR on ~4 KB/s with CommonCrypto (hardware AES) and ADTS parsing are negligible. AAC-LC decode of 16 kHz mono via AudioToolbox has no published cost figure, but it is a fraction of real-time playback decode. **Expected total: around 1–5% of one core averaged.** That is more than 15x below the 50%/180 s threshold and the 80%/60 s monitor. The crash-log wording ("N seconds cpu time over M seconds") suggests the monitor sums CPU time across all threads against wall time. If so, multi-threaded ML bursts count fully. This is an inference from the log format.
- **Adding Parakeet in the BLE background on iOS 27.0.1:**
  - *Without the inference entitlement:* the ANE is restricted per the release notes. What Core ML/FluidAudio does then (falls back to CPU, errors, or stalls) is undocumented. A CPU-only encoder on a 0.6B model, run on minutes of queued speech, could easily sustain multi-core load for tens of seconds. That is exactly the shape that trips "80% over 60 s" or "50% over 180 s". It also adds a ~600 MB footprint in a process iOS is already keeping alive in the background.
  - *With the entitlement:* the name ("continued-processing.inference") suggests it is scoped to `BGContinuedProcessingTask` work, which must be started from the foreground by a user action. Whether it also covers a BLE-woken app, or a `BGProcessingTask`, is unknown.
  - **Net:** treat "Parakeet in the BLE wake path" as unsupported on iOS 27 until a device test shows ANE execution in the background with `highCPUTerminationCount == 0`.
- **SpeechTranscriber:** inference runs in Apple's speech service, not obviously in the app's process. It may therefore avoid the app's CPU monitor and memory charge, but no Apple document says so, and Apple could equally restrict it in the background. It is worth A/B testing as the "live while backgrounded" candidate. It is still not a basis for the architecture.
- **Foundation Models extraction in the BLE background:** allowed but best-effort ("throttled or canceled"). Queue it, make it resumable and idempotent, and never let it block capture.
- **Architecture implication:** the evidence favours capture-then-batch with a thin live layer. The always-on path does decrypt, validate, append ADTS to disk, and at most VAD on CPU. ASR and diarization run (a) live only while FreeBee is in the foreground, (b) in a user-started `BGContinuedProcessingTask` ("Process today"), and (c) in an overnight `BGProcessingTask(requiresExternalPower: true)`, which disables the CPU monitor. Whether (b) and (c) get the ANE on iOS 27 depends on the inference entitlement and must be tested.

### Gaps
- No measured CPU% for AES-CTR + ADTS + AAC decode + Silero on A19 Pro. Measure it with Instruments (CPU Profiler / Power Profiler) and MetricKit `cpuTime` on the device.
- The CPU monitor thresholds for iOS 26/27 `bluetooth-central` apps are not documented. Only 80%/60 s and 50%/180 s are observed in crash logs, of unknown OS vintage.
- Unknown: (1) whether `com.apple.developer.background-tasks.continued-processing.inference` is self-serve in the developer portal or requires a request; (2) whether it applies outside `BGContinuedProcessingTask`, for example to BLE-woken execution or `BGProcessingTask`; (3) what Core ML/Core AI do when ANE access is denied (CPU fallback vs. error). None of these appear in the iOS 27.1 SDK headers or Xcode.
- No public test of SpeechTranscriber/SpeechAnalyzer running while an app is backgrounded on iOS 27.

## Q3. Does the archived "around 10 s per wake" rule still apply on iOS 26/27, and does a continuous notification stream count as "too much time executing in the background"?

### Takeaway
No current Apple source restates or replaces the 10 s figure, so it is neither confirmed nor refuted for iOS 26/27. Apple's current Bluetooth background documentation (TN3115) covers relaunch rules only. Quinn's background-execution FAQ (last updated 2026-01-09) does not mention Bluetooth time budgets. Field behaviour (Omi, 16 h in the background) shows a continuously connected BLE app is not killed merely for running continuously. The binding limits are the CPU monitor, memory, and battery heuristics, not a per-wake clock.

### Cited Findings
- **Archived guide (iOS 7 era):** "Upon being woken up, an app has around 10 seconds to complete a task … Apps that spend too much time executing in the background can be throttled back by the system or killed." It also says woken apps should not do "extraneous tasks that are unrelated to why the app was woken up" — [Core Bluetooth Programming Guide (archived)](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **Quinn's "iOS Background Execution Limits" (DTS; last change 2026-01-09, which added AlarmKit and `BGContinuedProcessingTask`):**
  - It says iOS's "default behaviour is to suspend your app shortly after the user has moved it to the background".
  - It says each mechanism "fulfils a specific purpose. Do not attempt to use them for some other purpose", and cites App Review 2.5.4.
  - It says nothing about Bluetooth wake time budgets or the CPU monitor.
  - — [forums 685525](https://developer.apple.com/forums/thread/685525)
- **TN3115** (updated for iOS 26) covers only relaunch conditions (force quit, toggles, reboot), not execution time — [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- **DTS (Aug 2026) treats a connected link as the supported way to get ongoing background interaction:** "connect with your accessory and directly interact with it" — [forums 840468](https://developer.apple.com/forums/thread/840468)
- **Field evidence of continuous execution:** Omi showed 16h 19m in the background in one day, the process active and retiring ~150–300M instructions/s, with no CPU kill reported. It was confounded by `audio` mode and a held `AVAudioSession` — [omi #11307](https://github.com/BasedHardware/omi/issues/11307)

### Inferences
- The "10 s" figure probably still describes the per-event grace window for a woken, suspended app. At 8 events/s, though, the app is effectively never idle long enough to suspend. "Runs continuously" is therefore plausible, but it means "is scheduled continuously", not "may run arbitrary work". The guide's "extraneous tasks" warning and App Review 2.5.4 both point toward keeping the wake path to the Bluetooth task: receive, decrypt, store.
- A continuous stream is unlikely to count as "too much time" by itself. What gets apps killed in practice is CPU (the monitor), memory (jetsam) and, on iOS 27, restricted ANE/GPU access. For FreeBee, the BLE-only configuration (no `audio` keep-alive) is the cleaner test. If notifications keep arriving at ~8/s for 16 h while locked, the premise is confirmed for our case.

### Gaps
- No Apple document or DTS reply from 2025–2026 addresses execution time for a continuously notifying `bluetooth-central` app. A DTS Technical Support Incident or forum question citing FreeBee's measurements would be the only way to get an authoritative answer.

## Q4. On-body disconnect rate and RSSI over a day; negotiated ATT MTU, connection interval and PHY; percentage of the day lost with no device buffer

### Takeaway
Nobody has measured any of this for a Bee on iPhone. Apple states the iPhone, as central, picks the MTU. A Zephyr/Nordic peripheral that does Data Length Extension first will usually get a large MTU, but iOS's value can't be assumed to match macOS's 498. Omi's on-body iOS data is the only proxy: disconnects cluster at RSSI −91 to −97, with ~11–12 link drops across a ~10.5 h day. With no Bee buffer, each drop loses the whole gap plus reconnect, session reopen and warm-up. A daily loss percentage can only come from our own logs.

### Cited Findings
- **Apple: the central decides the MTU.** "When operating as a central, the Apple device will negotiate the optimal MTU size for that point in time… You cannot force a certain MTU from your peripheral, or from within your app". A peripheral with Data Length Extension "must perform the packet length update procedure before performing the Exchange MTU Request handshake" — Apple engineer reply, [forums 665058](https://developer.apple.com/forums/thread/665058) (quoted via search-result summary; author role not re-verified)
- **Observed iOS MTU values vary (all anecdotal):**
  - 185 on many peripherals (older iOS) — [Nordic DevZone 44825](https://devzone.nordicsemi.com/f/nordic-q-a/44825/ios-mtu-size-why-only-185-bytes)
  - 527 up to iOS 15, then 250 after iOS 16.1.1 for one peripheral — [forums 721541](https://developer.apple.com/forums/thread/721541)
  - MTU 517 giving `maximumWriteValueLength` 512 (iPhone 12) or 512/514 (iPhone X) — [CSDN article](https://aiot.csdn.net/69cbaf530a2f6a37c59bdd4b.html)
  - No iOS 26/27 or iPhone 17 data found.
- **Our Bee on macOS:** MTU 498, 495-byte notifications (4 B seq + 491 B ciphertext), inter-arrival median 120 ms / mean 122.8 ms, 0 lost — bee_device_audio.md (our capture (`captures/20261020-201740-raw.jsonl`)). The official Android app requests MTU 517 — [jkmills PROTOCOL.md](https://github.com/jkmills/bee-wearable-ble/blob/main/PROTOCOL.md)
- **Bitrate varies between units, so packet rate does too.** A Frida capture of the official Bee Android app 1.0.3 (another unit, firmware not recorded) gave 30 s → **468 frames / 29,904 bytes** (≈ 8.0 kbps), AAC-LC ADTS 16 kHz mono — [omi #20828 (2026-10-06)](https://github.com/BasedHardware/omi/issues/20828). Ours reports GetBitrate = 32000.
- **On-body disconnect proxies (Omi CV1, iOS 26.6):**
  - Disconnects at RSSI −91 to −97, 19/20 background `connection_timeout`, 983 lifetime reconnects.
  - In a separate factory-control day trace: 12 connects / 11 disconnects in ~10.5 h of "normal in/out-of-range use".
  - — [omi #11307](https://github.com/BasedHardware/omi/issues/11307)
- **Bee's own users:** "The pioneer disconnects ALL THE TIME if Bee isn't in the background/foreground apps" — [App Store listing](https://apps.apple.com/us/app/bee-your-personal-ai/id6480349491) (via bee_device_audio.md)
- **Connection parameters cannot be set from the app.** Even CBPeripheralManager offers no public API for connection interval, latency or supervision timeout (a developer saw a 720 ms supervision timeout on macOS) — [forums 843320](https://developer.apple.com/forums/thread/843320)

### Inferences
- **Measurement recipe:**
  - Log `peripheral.maximumWriteValueLength(for: .withoutResponse)` (= ATT MTU − 3) right after connect, and the byte count of every notification.
  - If notifications are not always MTU − 3, the firmware fills to a fixed size, not the MTU. This only shows on iPhone if the iPhone MTU is below 498.
  - Install Apple's Bluetooth logging profile, capture a sysdiagnose after a session, and open it in PacketLogger. Read `LE Connection Complete` / `LE Connection Update Complete` (interval, latency, supervision timeout), `LE PHY Update Complete` (1M/2M) and `LE Data Length Change`.
  - Log RSSI once a minute in the background (not every 4 s) plus at every disconnect, to build the disconnect-vs-RSSI curve.
- **Loss accounting with no device buffer:** loss per drop = (time disconnected) + (connect → SetEncryptionKey → GetSessionNonce → subscribe) + 3 warm-up frames (3 × 64 ms = 192 ms) + the first partial frame.
  - Worked example: Omi's in-range pattern of ~11 drops/day with ~5–10 s recovery each would lose roughly 1–2 min/day, about 0.1–0.2% of a 16 h day.
  - Out-of-range time (phone left on a desk) is lost 1:1, and pathological cases like Omi's reconnect storms or hours-long stalls dominate.
  - The real figure has to come from Σ(gap durations) ÷ (session wall time) in our own logs.
- **Compute gaps from wall-clock and decoded frames, not Δseq × constant.** Each ADTS frame is exactly 1024 samples = 64 ms at 16 kHz. Lost audio = (wall time between the last good and the first good frame) − (decoded frames × 64 ms) over that window. Also cross-check expected frames = wall-time ÷ 64 ms. This works at any MTU or bitrate.

### Gaps
- iPhone 17 Pro / iOS 27 negotiated MTU, connection interval, PHY and DLE for Bee firmware 0.6.1: unmeasured. Only a PacketLogger trace on the device can answer this.
- No on-body RSSI or disconnect data for the Bee (wrist or clip placement) with an iPhone in a pocket.
- No source says whether the Bee buffers even a few frames across a short link drop. The assumption of no buffer comes from the earlier notes.

## Q5. After a user force-quit, does the iOS 26+ AccessorySetupKit relaunch (TN3115 note 5) actually fire for FreeBee, restore the session and re-subscribe?

### Takeaway
Apple's documentation and two separate DTS engineers (Aug and Sep 2026) say yes for ASK apps on iOS 26+. No public field report confirms it working, and one developer (iOS 26.5) reports it not firing, in a thread still unresolved. That developer relied on background advertisement scanning, which DTS says is coalesced, rather than a pending connection. FreeBee should test it directly with a pending `connect()` and an ungated launch notification.

### Cited Findings
- **TN3115 (updated for iOS 26):** "Force Quit: No (see note 5)", "Control Center Bluetooth button toggled: Yes (see note 5)". Note 5 says that starting in iOS 26, only apps that use AccessorySetupKit to set up Bluetooth accessories will be relaunched — [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- **Apple engineer (Nov 2025):** "An app that was force quit was never able to be relaunched before. iOS 26 actually adds the capability for such apps to be launched if they opt in to use AccessorySetupKit." — [forums 806013](https://developer.apple.com/forums/thread/806013)
- **DTS, Richard Yeh (Sep 2026):** "Force quitting will not cause Bluetooth State Restoration to relaunch an app unless your app uses AccessorySetupKit and is running on iOS 26 and above." — [forums 844477](https://developer.apple.com/forums/thread/844477)
- **DTS, Kevin Elliott (Aug 2026):** "My understanding, per TN3115, is that AccessorySetupKit will relaunch force-quit apps." He adds that he worked closely with the TN3115 author and is "confident that he would not have documented that detail unless the engineering team had specifically confirmed that this was the behavior they intended to support." — [forums 840468](https://developer.apple.com/forums/thread/840468)
- **Counter-report (unresolved):**
  - Setup: iOS 26.5, Xcode 26.3, ASK-authorized app, `bluetooth-central`, constant restore ID, waking on BLE advertisements via `scanForPeripherals`.
  - Result: after a force-quit, "BLE events do not wake or relaunch the app".
  - DTS asked the developer to validate normal (non-force-quit) termination first, and pointed out that background discoveries are coalesced. No resolution was posted.
  - — [forums 840468](https://developer.apple.com/forums/thread/840468)
- **Anecdote in the other direction:** an app (ASK use not stated) seemed to run after a force-quit when a peripheral that had been off for a week came back. The developer suspected a pending connect — [forums 844477](https://developer.apple.com/forums/thread/844477)
- **Reboot:** after a reboot, apps are not relaunched until first unlock — [TN3115 note 4](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- **Related ASK pitfall:** after migrating to ASK, a new `CBCentralManager` could reach only the newly authorized accessory, and previously known peripherals were no longer discovered — [forums 842777](https://developer.apple.com/forums/thread/842777)

### Inferences
- FreeBee's relaunch trigger should be a **pending `connect()`** to the known ASK peripheral, left outstanding when the link drops. A connection event is what state restoration is designed to deliver. Passive scanning gets coalesced in the background.
- **Test matrix**, with an ungated local notification in `application(_:didFinishLaunchingWithOptions:)` and a log of `launchOptions[.bluetoothCentrals]` plus `willRestoreState` keys:
  1. Developer → Fast App Termination on, then background → walk away → return. This is the baseline restoration that DTS says to verify first.
  2. Force-quit with the Bee connected → walk out of range → return.
  3. Force-quit, then turn the Bee off and on.
  4. Control Center Bluetooth toggle off and on.
  5. Reboot without unlocking (should not relaunch), then unlock (should).
- In each case, measure time from the relaunch to `didConnect`, then to the nonce, then to the first valid ADTS frame. The session must be re-opened (new nonce) and the audio CCCD re-subscribed after every restoration. The Keychain item's `AfterFirstUnlockThisDeviceOnly` class allows this while the phone is locked.

### Gaps
- No public confirmation that the ASK force-quit relaunch works in practice on iOS 26.x/27.x for a connection-based trigger. The only detailed report is negative, and it used advertisement scanning.

## Q6. Phone battery drain per hour: capture-only vs. capture plus live ASR

### Takeaway
No published measurement exists for any BLE audio wearable app on iPhone. Omi, the largest open-source project in this space, says "no phone energy has ever been measured" (Sept 2026). Its 51%/16 h figure is confounded by an audio session, a foreground task, polling and reconnect storms, and Omi itself attributes most of it to "preventing suspend + radio + audio". FreeBee has to measure this itself.

### Cited Findings
- "Heavy background drain is a recurring complaint … **no phone energy has ever been measured** for them". Omi's proposed protocol: same phone, pendant and firmware; 3 × 30-minute runs per state across six states (disconnected idle, connected+muted, live speech, connected+silence, offline catch-up, weak network); report discharge per hour, CPU wakeups, bytes sent and recovery latency; use Instruments Power Profiler and an external power meter if available — [omi #19565 (2026-09-28)](https://github.com/BasedHardware/omi/issues/19565)
- **The 51% case:** 4 min on screen, 16 h 19 min background, "ran in the background 4h 10m longer than usual". Sampled CPU-side coalition energy was 38.15 mWh, and the author concludes the 51% is "mostly preventing suspend + radio + audio, not Dart burning a core" — [omi #11307](https://github.com/BasedHardware/omi/issues/11307)
- **iOS disk-write budget:** Omi's `diskwrites_resource` report gave "limit 12.43 KB/s" (≈ 1.07 GB per 24 h) after it dirtied 1,074 MB in 5.3 h — [omi #11307](https://github.com/BasedHardware/omi/issues/11307). iOS 27 MetricKit exposes `DiskWriteExceptionDiagnostic` and `logicalDiskWrites` — iPhoneOS27.1.sdk `MetricKit.swiftinterface` (local)
- Consumer-blog "%/hour for Bluetooth" figures (1.2% to 5.1%/h) carry no methodology and are not usable — [search-result set, e.g. pairexa](https://pairexa.com/does-bluetooth-drain-battery/)

### Inferences
- **Disk writes:** raw ADTS at ~4 KB/s is ~0.35 GB/day, about a third of the ~1.07 GB/day disk-write threshold. Writing decoded PCM (16 kHz × 16-bit = 32 KB/s ≈ 2.8 GB/day) or WAV segments for later ASR would blow through it. So capture-then-batch should store ADTS and decode at processing time. Batch log flushes too, rather than writing per notification.
- **Expected ordering** (to verify):
  - Capture-only, no `audio` session, no polling: cost dominated by radio and wakeups. Probably modest, but unknown.
  - Capture + CPU VAD: small increment, a few % of one core.
  - Capture + live ASR in the background: if the ANE is denied on iOS 27, CPU ASR is the most energy-expensive option and the most kill-prone.
  - Batch ASR on a charger: zero battery cost by construction.
- **Suggested measurement:** follow Omi #19565's design on the iPhone 17 Pro. Use Settings → Battery attribution, Instruments Power Profiler (untethered recording), and MetricKit `cpuTime` / `totalBackgroundTime` / `cpuInstructionsCount`. Run four states: muted-connected, capture-only, capture+VAD, and capture+live ASR (SpeechTranscriber, and Parakeet if the ANE is available). Each state needs at least 3 × 60 min with screen off, plus one full day for capture-only.

### Gaps
- No primary measurement of iPhone drain per hour for sustained ~8 notifications/s at ~4 KB/s.
- No battery data for SpeechTranscriber or Parakeet on iPhone 17 Pro, in either foreground or background.
- Whether the disk-write report is fatal or only diagnostic on iOS 27 was not verified.

## Q7. Fact-check of doubtful claims from the earlier notes

### Takeaway
Two claims are corrected with primary sources: Foundation Models tier detection, and iOS 27 `rateLimited` handling. Two are corrected on the facts already in our own notes: the MTU/123 ms conversion and ADTS CRC. The force-quit claim is corrected on the documentation but still unverified in practice. The other three are single-source or unverifiable as stated.

### Cited Findings
1. **"iOS won't relaunch one the user force-quit" (bee_device_audio.md): CORRECTED, but unverified in practice.**
   - For ASK-paired apps on iOS 26+, TN3115 note 5 says force-quit and Control Center toggles do relaunch. Two DTS engineers reaffirmed this in Aug/Sep 2026 — [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules); [forums 806013](https://developer.apple.com/forums/thread/806013); [forums 844477](https://developer.apple.com/forums/thread/844477); [forums 840468](https://developer.apple.com/forums/thread/840468).
   - The claim is still true for non-ASK apps and before first unlock after a reboot (note 4).
   - One unresolved iOS 26.5 report says it didn't fire for an advertisement-scan wake — [forums 840468](https://developer.apple.com/forums/thread/840468).
2. **"~10 s per wake" therefore "effectively runs continuously" (ios_ble_background_streaming.md): UNVERIFIABLE as stated.**
   - The 10 s figure exists only in the archived guide. Apple's 2026 background FAQ and TN3115 neither restate nor revise it — [archived guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html); [forums 685525](https://developer.apple.com/forums/thread/685525).
   - Continuous background execution of a BLE-pendant app is supported by Omi's field data, but that is confounded by `audio` mode and is from iOS 26.6 — [omi #11307](https://github.com/BasedHardware/omi/issues/11307).
   - Even if "runs continuously" holds, it does **not** imply "may run ANE ML": iOS 27 restricts background ANE access without a new entitlement — [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes). The premise for running ML in the background in the other notes is therefore weaker than stated.
3. **"~494-byte notifications imply MTU ≥ ~497; gaps = Δseq × ~123 ms" (ios_ble_background_streaming.md): CORRECTED.**
   - The measured values are 495 B notifications = 4 B seq + **491 B** ciphertext at MTU **498**, on **macOS**. The iPhone MTU is unmeasured — bee_device_audio.md (our capture (`captures/20261020-201740-raw.jsonl`)).
   - Apple says the central picks the MTU, and an app or peripheral can't force it — [forums 665058](https://developer.apple.com/forums/thread/665058) (via search summary).
   - Another Bee unit streams ≈ 8 kbps (468 frames / 29,904 B in 30 s) — [omi #20828](https://github.com/BasedHardware/omi/issues/20828).
   - Frames are VBR (213–345 B) — bee_device_audio.md.
   - Δseq × 123 ms is only valid at MTU 498 and 32 kbps. Use the wall-clock and 64 ms-per-frame method from Q4.
4. **"Integrity can only be sanity-checked via ADTS syncword/CRC"; "check whether AudioFileStream handles ADTS with CRC" (ios_ble_background_streaming.md): CORRECTED.**
   - `protection_absent = 1` in all 698 measured frames, so there is no CRC. AES-CTR has no auth tag — bee_device_audio.md (our capture .aac (`captures/20261020-201740.aac`)).
   - Validation is: 12-bit syncword 0xFFF; fixed-header invariants (MPEG-4 ID, AAC-LC profile, sampling index 8, channel config 1, `protection_absent` 1, one raw data block); plausible `frame_length` (> 7 per the official app's stop rule — [jkmills PROTOCOL.md](https://github.com/jkmills/bee-wearable-ble/blob/main/PROTOCOL.md) — and ≤ about 2× the max seen); the next syncword exactly `frame_length` bytes later; seq continuity; decoder error status.
   - The AudioFileStream CRC question is moot.
5. **"Only Apple's Foundation Models is reliably usable in the background … the only LLM path Apple sanctions for background work" (on_device_llm_summarization.md): CORRECTED (the "reliably" part is unsupported).**
   - Apple engineers say that in the background on iOS 27, requests "might be throttled or canceled" — [forums 833642](https://developer.apple.com/forums/thread/833642) — and that "the OS manages the requests … There's no entitlement or API to influence this" — [forums 833666](https://developer.apple.com/forums/thread/833666).
   - A precision fix to the fact-check premise itself: iOS 27 did **not** drop rate limiting. `LanguageModelSession.GenerationError.rateLimited` is deprecated with the message "Use `LanguageModelError/rateLimited(_:)` instead". The new `LanguageModelError.RateLimited` carries a `resetDate: Date?` — iPhoneOS27.1.sdk `FoundationModels.swiftinterface` lines 1527–1566 and 3559–3562 (local). Map both error types — [react-native-foundation-models #20](https://github.com/henrypldev/react-native-foundation-models/issues/20).
   - A developer reports "Request has been rate limited" in the **foreground** from the first request — [graphghan #176](https://github.com/tylervick/graphghan/issues/176) (search summary, not fetched).
   - Relative to third-party ANE models, which now need an entitlement in the background, Foundation Models may still be the *least restricted* background LLM path. That is an inference, not a measurement.
6. **"iPhone 17 Pro gets AFM 3 Core Advanced 20B sparse; context 8192" (on_device_llm_summarization.md): tier CONFIRMED by Apple staff; "no API to tell the tier" CORRECTED; context UNRESOLVED.**
   - Apple staff (Aug 2026): "iPhone Air, iPhone 17 Pro, iPhone 17 Pro Max -> run AFM 3 Core Advanced 20B model in iOS 27.0"; iPhone 15 Pro/16 and later run "AFM 3 Core 3B"; "`SystemLanguageModel.variant` should tell you which model is running". The engineer recommends variant-specific prompts, instructions and chunking — [forums 843063](https://developer.apple.com/forums/thread/843063).
   - The SDK has `SystemLanguageModel.variant` with `.core3` and `.coreAdvanced3` — iPhoneOS27.1.sdk `FoundationModels.swiftinterface` lines 470–501 (local).
   - Apple staff (June 2026) also confirmed the two tiers, gated to devices with ≥12 GB — [forums 832910](https://developer.apple.com/forums/thread/832910); [MacRumors, 2026-06-08](https://www.macrumors.com/2026/06/08/most-powerful-on-device-ai-now-requires-iphone-17-pro-or-air/).
   - "1–4B active" is the forum OP's description, not the Apple engineer's — [forums 843063](https://developer.apple.com/forums/thread/843063).
   - Context sources conflict. The 843063 OP first said both devices report "roughly 4,096 tokens", then updated to 8K on the 17 Pro Max — [forums 843063](https://developer.apple.com/forums/thread/843063). A measured run on the iOS 27.1 simulator and macOS 27.0 gave `contextSize` = 4,096, with a 9,060-token prompt refused for exceeding 4096 (2026-10-15) — [socket-link/ampere PR #1021](https://github.com/socket-link/ampere/pull/1021). An iOS 26.5 simulator also reported 4096 — [watch-audio PR #199](https://github.com/Soichiro5/watch-audio/pull/199).
   - The resolution is to read `contextSize` and `variant` on the iPhone 17 Pro at runtime and size chunks from them.
7. **"~6 GB per-app memory ceiling" plus the iPhone 17 Pro tok/s, memory and J/token tables (on_device_llm_summarization.md): UNVERIFIABLE (single source).**
   - The ceiling is one developer's `os_proc_available_memory()` measurement on a 16 Pro Max and a 17 Pro Max (about 6 GB even with `increased-memory-limit`; ~6,656 MB with the debugging entitlement; FB23183521). No Apple reply was found — [forums 834805](https://developer.apple.com/forums/thread/834805).
   - New iOS 27 fact that changes the accounting: ANE memory "is now attributed to your app process instead of the system" — [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes). Footprints measured on iOS 26 for ANE models undercount what iOS 27 charges the app, both for the ceiling and for jetsam.
   - The single-author benchmark tables (MLBoy/john-rocky) and the Gemma 4 E2B memory inconsistencies were not re-checked this session, so they remain unverifiable.
8. **"SpeechTranscriber 14.0% WER, between whisper-base and whisper-small, 70x" (on_device_speech_audio_ml.md): CONFIRMED as reported, but weak.**
   - The only source is Argmax's own blog: earnings22 10% subset; SpeechTranscriber 14.0 at 70x vs. Argmax Parakeet v2 11.7 at 359x; about 16 months old — [Argmax](https://www.argmaxinc.com/blog/apple-and-argmax). No 2026 independent SpeechTranscriber WER benchmark, and no iPhone or far-field data, was found.
   - The language-count conflict is partly definitional: 10 *languages* at launch (Cantonese, Chinese, English, French, German, Italian, Japanese, Korean, Portuguese, Spanish) — [AddPipe blog](https://blog.addpipe.com/apple-speechanalyzer-api.md) — vs. "about 40 locales" — [issoh.co.jp](https://www.issoh.co.jp/tech/details/8929/). `supportedLocales` returns empty on the Simulator, so check it on the device — [forums 802969](https://developer.apple.com/forums/thread/802969).
   - Production asset risk: Omi users hit `Failed to access assets` from Apple's on-device recognizer (the `SFSpeechRecognizer` path) in Oct 2026 — [omi #20484](https://github.com/BasedHardware/omi/issues/20484).

### Inferences
- The three corrections that change architecture decisions:
  1. Background ANE is entitlement-gated on iOS 27. This weakens "Parakeet in BLE background" and favours capture-then-batch.
  2. The tier is detectable through `variant`. Use Core Advanced-specific prompts and chunking on the 17 Pro, and decide on an open model for the daily rollup only after measuring `contextSize` on the device.
  3. ANE memory now counts against the app. Re-measure every model's footprint on iOS 27 before keeping it resident in a background process.
- A decrypted ADTS header doubles as a cheap known-plaintext check of the session: if the first two bytes after decryption aren't 0xFFF1, the key or nonce is wrong. That gives a fast "session valid" signal after each reconnect, before any audio is decoded.

### Gaps
- No Apple statement resolves `contextSize` on a physical iPhone 17 Pro (4K vs. 8K).
- No independent 2026 SpeechTranscriber accuracy data. A Bee-audio A/B (SpeechTranscriber vs. Parakeet v3 vs. WhisperKit) on the user's own recordings is still needed.
- The MLBoy/john-rocky LLM tables and the Gemma 4 E2B memory figures were not re-verified this session.
