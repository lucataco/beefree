# iOS 26/27 platform constraints and architecture for all-day BLE audio ingestion + on-device processing (FreeBee)

Scope note: researched 2026-10-20. Primary sources are Apple docs, tech notes, DTS forum answers, WWDC25 session 227, and the local Xcode 27.1 / iPhoneOS27.1 SDK headers on this machine. I found **no WWDC 2026 session** that changes Core Bluetooth background execution or BackgroundTasks limits. The only iOS 27 Core Bluetooth additions in the SDK are Channel Sounding APIs. Treat the iOS 26 rules below as still current on iOS 27 unless noted.

Workload numbers used throughout (from the project's own measurements, not re-derived): 32 kbps AAC-ADTS at 16 kHz mono. 45 s = 366 notifications = 698 ADTS frames, i.e. about 8.1 notifications/s, about 15.5 frames/s, and about 490 bytes of ciphertext per notification.

## 1. Background lifetime: does a continuously notifying characteristic keep the app alive? Relaunch rules, CPU/memory limits, real-world reports

### Takeaway
With `bluetooth-central`, iOS wakes the app for every delegate callback, including each characteristic notification. In practice, ~8 notifications/s gives near-continuous background execution, but only in short bursts. Apple documents roughly 10 s per wake and says apps that run too long "can be throttled back by the system or killed". An undocumented CPU monitor (crash logs show "80% cpu over 60 seconds") and jetsam memory pressure also apply. So the background path must stay light: decrypt, reassemble, append to a file. Heavy ML must not run there. Since iOS 26, AccessorySetupKit (ASK) apps gain relaunch after force-quit and after a Control Center Bluetooth toggle. Real-world always-on apps (Omi) still see long background reconnect gaps, and they rely on device-side storage as a backstop.

### Cited Findings
- **bluetooth-central wake semantics**: "the system wakes up your app when any of the CBCentralManagerDelegate or CBPeripheralDelegate delegate methods are invoked … when a peripheral sends updated characteristic values" — [Apple Core Bluetooth Programming Guide (archived), Performing Long-Term Actions in the Background](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **Time budget per wake**: "Upon being woken up, an app has around 10 seconds to complete a task … Apps that spend too much time executing in the background can be throttled back by the system or killed." The same guide says apps "should be session based and provide an interface that allows the user to decide when to start and stop the delivery of Bluetooth-related events", and woken apps should not perform "extraneous tasks that are unrelated to why the app was woken up". (This guide is archived and older; I found no newer Apple document that restates or changes the 10 s figure.) — [Apple Core Bluetooth Programming Guide (archived)](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **Pending connects never time out**: "because connection requests do not time out, the iOS device will reconnect when the user returns home". This is the basis for issuing `connect()` immediately on disconnect. — [same archived guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **TN3115 relaunch table (updated 2025-09-15 for iOS 26)**:
  - App removed from memory: Yes. App crashed: Yes.
  - Force Quit: "No (see note 5)". Bluetooth power toggled in Settings: No. Control Center Bluetooth button toggled: "Yes (see note 5)".
  - Airplane Mode: Yes, "only if Bluetooth is not toggled with Airplane Mode".
  - Device restarted: Yes, but "apps will not be relaunched until the device is unlocked for the first time after a restart".
  - Note 5: "Starting in iOS 26 and iPadOS 26, only apps that use AccessorySetupKit to setup Bluetooth accessories will be relaunched."
  - Relaunch happens "if and only if it's waiting for a specific Bluetooth event or action (like scanning, connecting, or a subscribed notification characteristic…)".
  - [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- **Apple engineer clarification of Note 5 (Nov 2025)**: Note 5 "only pertains to the specific cases where Note 5 is referred to, namely: if the app Force Quit by the user [and] Control Center Bluetooth button toggled. An app that was force quit was never able to be relaunched before. iOS 26 actually adds the capability for such apps to be launched if they opt in to use AccessorySetupKit." In other words, non-ASK apps did not lose restoration in general. — [Apple Developer Forums 806013](https://developer.apple.com/forums/thread/806013). Some developers misread Note 5 as "restoration doesn't work on iOS 26" — [react-native-ble-manager #1386](https://github.com/innoveit/react-native-ble-manager/issues/1386).
- **DTS general position (Quinn, "iOS Background Execution Limits", last updated 2026-01-09)**:
  - On running continuously in the background: "You can't." iOS suspends apps "shortly after the user has moved it to the background".
  - Each background mode "fulfils a specific purpose. Do not attempt to use them for some other purpose". `audio` is for apps like music players. App Review 2.5.4 applies.
  - Force-quit blocks background launch until the user relaunches.
  - [Apple Developer Forums 685525](https://developer.apple.com/forums/thread/685525)
- **CPU monitor**:
  - Crash/energy logs show "48 seconds cpu time over 55 seconds (87% cpu average), exceeding limit of 80% cpu over 60 seconds", with action "process killed". This happens even inside BGProcessingTask. — [Apple Developer Forums 690666](https://developer.apple.com/forums/thread/690666); [SwiftRocks, CPU exceptions via Energy Organizer](https://swiftrocks.com/debug-cpu-exceptions-xcode-energy-reports)
  - Apple's archived Energy Guide shows the same "(Limit 80%) Observed 89% over 60 seconds" exception. — [Energy Efficiency Guide for iOS (archived)](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html)
  - I found no current Apple document that publishes the threshold as a guarantee.
- **CPU monitor can be disabled on charger**: in the iOS 27.1 SDK, `BGProcessingTaskRequest.requiresExternalPower` is documented as: "Setting this to `YES` will also disable the CPU Monitor feature. Specify `YES` if this task is resource intensive to minimize impact to battery life." — iPhoneOS27.1.sdk `BackgroundTasks.framework/Headers/BGTaskRequest.h` (local SDK); [requiresExternalPower docs](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresexternalpower)
- **Memory / jetsam**: background apps get killed when "The system experienced memory pressure and needed to free background process memory for the current foreground app" (`vm-pageshortage`). Background apps can also be killed to free vnodes or file cache "even if your app isn't the source". `per-process-limit` applies to all apps, and extensions have "a much lower per-process memory limit". No numeric limits are published. — [Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)
- **WWDC25 "Finish tasks in the background"**:
  - Background execution "isn't guaranteed. Instead, it's opportunistic, often discretionary, and tightly managed".
  - "If a backgrounded app consumes too much memory or CPU, it's not just inefficient. It's also competing with the foreground experience."
  - "If your app drains too much battery in the background, [people] may take action".
  - [WWDC25 session 227](https://developer.apple.com/videos/play/wwdc2025/227/)
- **iOS 27 Core Bluetooth deltas**: the only `API_AVAILABLE(ios(27.0))` symbols in the iPhoneOS27.1 Core Bluetooth headers are Channel Sounding (`CBCentralManagerFeatureChannelSounding`, `startChannelSoundingSession:`, related errors and delegates). Nothing changes background execution. — local SDK `CoreBluetooth.framework/Headers/CBCentralManager.h`, `CBPeripheral.h`, `CBError.h`; see also [WWDC26 Session 369 summary (third-party)](https://wwdc.ai/2026/369). The WWDC26 new-framework list has no Bluetooth/background-execution framework. Its additions include CoreAI, FoundationModels updates, MediaIntelligence, StateReporting and others. — [All new frameworks presented at WWDC26 (Eidinger)](https://blog.eidinger.info/all-new-frameworks-presented-at-wwdc26)
- **Background scanning is slowed, not stopped** (Apple engineer, Feb 2026): "the scanning will not stop, but will slow down by a lot when the app is no longer in the foreground". Recommended advertising intervals for discovery: 20 ms, 152.5 ms, 211.25 ms, 318.75 ms, 417.5 ms, 546.25 ms, 760 ms, 852.5 ms, 1022.5 ms, 1285 ms. A CoreLocation/CoreBluetooth interaction is "an unintended undocumented side effect" and should not be relied on. — [Apple Developer Forums 814681](https://developer.apple.com/forums/thread/814681)
- **Real-world: Omi (BasedHardware), issue #11307, opened Aug 2026, P1, open**:
  - A production iOS app on firmware 3.0.21 logged repeated CoreBluetooth `connection_timeout` failures, all while backgrounded. Reconnect gaps ranged from ~3.9 s to ~7,335 s (~2 h).
  - On an iOS 26.6 / iPhone 15 Pro Max device, 19 of the last 20 disconnects were background `connection_timeout` at RSSI −91 to −97, with 983 reconnects and 137 failed connects.
  - iOS attributed 51% of battery to the app over 16 h in background. Suspected causes: an audio session kept active, a foreground task, a 5 s battery poll, and reconnects with no backoff.
  - A commit "stop background audio keep-alive and back off BLE timeouts" was reverted the same day.
  - Firmware bugs also played a part: the pendant mic slept during a disconnect and never woke, and firmware discards frames when connected but not subscribed.
  - "Durable on-device storage prevented audio loss, but live transcription stayed unavailable until the app returned to the foreground."
  - Proposed rules: "connection is not readiness until fresh frames arrive", reconnection must restore the audio subscription, and a bounded watchdog is needed.
  - [BasedHardware/omi #11307](https://github.com/BasedHardware/omi/issues/11307)
- **Omi iOS background modes**: Omi's shipping `Info.plist` declares `UIBackgroundModes` = audio, location, bluetooth-central, fetch, processing, remote-notification, voip. That is a "kitchen sink" approach. — [omi app/ios/Runner/Info.plist](https://github.com/BasedHardware/omi/blob/main/app/ios/Runner/Info.plist)
- **Other Omi lessons**:
  - Proposed Android fix: a heartbeat so firmware falls back to SD storage when the app stops consuming — [omi #6570](https://github.com/BasedHardware/omi/issues/6570)
  - A failed codec read caused Opus to be decoded as PCM8 (garbled), so codec reads must be retried — [omi #20779](https://github.com/BasedHardware/omi/issues/20779)
  - Re-arm STT after BLE capture resumes — [omi PR #22094](https://github.com/BasedHardware/omi/pull/22094)
- **Other wearables use store-and-forward rather than all-day live streaming**:
  - Plaud NotePin S records offline with 64 GB local storage and syncs to the app/cloud — [Plaud support](https://support.plaud.ai/hc/en-us/articles/53771056805785-Does-Plaud-NotePin-S-work-offline)
  - The Limitless pendant syncs over Bluetooth to the app — [Limitless help](https://help.limitless.ai/en/articles/9135592-how-will-the-pendant-work-with-limitless) (old page)

### Inferences
- At ~8 notifications/s, the ~10 s per-wake window is renewed every ~125 ms. A connected, subscribed `bluetooth-central` app therefore effectively runs continuously while streaming. The binding constraints are the CPU monitor (keep sustained CPU far below ~80% of one core; target low single-digit %), memory (stay small to avoid `vm-pageshortage` jetsam), and battery heuristics. This matches Omi's experience: the stream itself works in background, and failures come from disconnects/reconnect logic and heavy side work.
- Do **not** add the `audio` background mode as a keep-alive. BLE notifications already keep the app scheduled. Omi's experience suggests audio keep-alive is a major battery cost, and it conflicts with App Review 2.5.4 if the app is ever distributed. FreeBee's existing config (`bluetooth-central` only, in `Support/Bee-AccessorySetupKit.plist`) is the right baseline.
- Because FreeBee pairs via ASK, it benefits from the iOS 26 force-quit / Control Center relaunch extension. A reboot still blocks relaunch until first unlock (TN3115 note 4). On restoration the app must re-open the Bee session (SetEncryptionKey → GetSessionNonce), because the nonce is per-session, and then re-subscribe to the audio characteristic.
- Every Bee disconnect forces a session re-open and loses audio while disconnected. Bee firmware 0.6.1 is not known to buffer audio on-device (unlike Omi/Plaud). So FreeBee should expect real audio gaps in the background, and it should log gap durations from sequence numbers and wall-clock time.

### Gaps
- No Apple source states whether the "around 10 seconds" figure still applies on iOS 26/27, or how it interacts with continuous notification streams. The archived guide is the only primary source.
- No published per-process background memory limit for iPhone 17 Pro / iOS 27. No published CPU-monitor thresholds. Search snippets also mention a "50% cpu over 180 seconds" variant in forum crash logs, but I did not verify the thread.
- I found no public engineering write-ups from Limitless, Plaud, Bee/Amazon, hearing-aid or CGM vendors about iOS background BLE streaming internals. Hearing aids typically use Apple's MFi/ASHA-style system paths, which third-party apps can't use (not verified for this note).
- I found no Apple statement that ASK pairing grants any extra background *execution* privilege beyond the iOS 26 relaunch cases.

## 2. Heavy ML (STT, diarization, LLM) in the background: BGProcessingTask, BGContinuedProcessingTask, Live Activities, audio mode, ASK

### Takeaway
On iPhone, heavy ML in the background is possible only in constrained forms:
- **BGProcessingTask**: system-scheduled, typically overnight. With `requiresExternalPower = YES` it disables the CPU monitor, which makes it the best fit for bulk "charge-time" transcription, diarization and summarization.
- **BGContinuedProcessingTask (iOS 26+)**: must be started by an explicit user action in the foreground. It shows system progress UI, can be cancelled by the user, gets lower QoS, and has **no background GPU on iPhone** per DTS.

Live transcription inside the BLE wake path risks CPU-monitor kills. The recommended architecture is: capture + store compressed audio in the background, run light VAD at most, and defer STT/diarization/LLM to foreground, user-initiated continued tasks, or on-charger BGProcessingTasks.

### Cited Findings
- **BGContinuedProcessingTask basics**: "A task that starts in the foreground and can continue running in the background as needed." "The system displays the progress of this task in a Live Activity and a person can cancel it." "The system prioritizes the termination of tasks that reflect minimal or no progress, when resources become constrained." — [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- **Submission rules**: submission "needs to occur as a result of a person's action, such as tapping a button" — [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest)
- **Allowed work**: continued tasks can perform "Core ML processing or sensor data analysis, that leverage the GPU (on supported devices)" and "intensive CPU-based operations". "The system cancels any running tasks if a person closes the app in the app switcher, but the app doesn't receive an indication of cancellation in that case." — [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- **SDK header (iOS 27.1)**:
  - Default resources allow "background CPU and network access".
  - "Background GPU execution is not supported on all devices … if a device is experiencing heavy GPU contention backgrounded workloads are not guaranteed runtime."
  - GPU requires the entitlement `com.apple.developer.background-tasks.continued-processing.gpu`.
  - Queued requests "will be cancelled when the user removes your app from the app switcher".
  - Local SDK `BackgroundTasks.framework/Headers/BGTaskRequest.h`
- **No background GPU on iPhone (DTS, Nov 2025)**: Kevin Elliott (DTS) says enabling background GPU "won't help on the iPhone (it's not available there)". In the same thread, a Core ML (`.cpuAndNeuralEngine`) workload ran 4–5x slower in a background BGContinuedProcessingTask. DTS guessed that GPU loss was the cause but said "I'm not entirely certain". — [Apple Developer Forums 807957](https://developer.apple.com/forums/thread/807957). Developers report `supportedResources.contains(.gpu)` is false on iPhone 15 Pro / 16 Pro — [Apple Developer Forums 816774](https://developer.apple.com/forums/thread/816774)
- **WWDC25 session 227 guidance**:
  - Continued tasks "always start with an explicit action … Avoid automatic workloads like maintenance, backups, or photo syncing. Doing this unexpected work may lead to your app's task being canceled."
  - "tasks that do not report any progress will be expired".
  - "your background task may receive a lower quality of service compared to when your app is active … When your app does return to the foreground, it will intelligently boost your task priority."
  - "If a task doesn't need to run immediately, consider deferring it until the device is charging."
  - "Save incremental progress early and often."
  - [WWDC25 session 227](https://developer.apple.com/videos/play/wwdc2025/227/)
- **BGProcessingTask**: "typically delivered overnight when the user is asleep" — [Quinn, forums 685525](https://developer.apple.com/forums/thread/685525). With `requiresExternalPower = YES` it runs only on power and disables the CPU Monitor — [local SDK BGTaskRequest.h; docs](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresexternalpower). Even BGProcessingTasks without that flag have been killed by the CPU monitor about a minute in — [forums 690666](https://developer.apple.com/forums/thread/690666)
- **Foundation Models (on-device LLM) in the background**:
  - iOS 26 docs for `LanguageModelSession.GenerationError.rateLimited` say: "This error will only happen if your app is running in the background and exceeds the system defined rate limit." — [GenerationError.rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:))
  - That case is **deprecated in iOS 27** in favour of `LanguageModelError.rateLimited`, documented as "can happen if you make too many requests in a short window … recover … by spacing your requests or reducing system load". — [LanguageModelError.rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/ratelimited(_:)); local SDK FoundationModels swiftinterface
- **SpeechAnalyzer / SpeechTranscriber (iOS 26+)**:
  - `SpeechAnalyzer` is available from iOS 26.0. Modules include `SpeechTranscriber` and `SpeechDetector` (VAD).
  - Models come from `AssetInventory`, and `SpeechTranscriber.isAvailable/supportedLocales` must be checked, with `DictationTranscriber` as the fallback.
  - You can feed buffers directly via an `AsyncSequence` of `AnalyzerInput` after converting to a supported format. Current docs also list helper providers (`AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, `AnalyzerInputConverter`).
  - [SpeechAnalyzer docs](https://developer.apple.com/documentation/speech/speechanalyzer); [SpeechTranscriber docs](https://developer.apple.com/documentation/speech/speechtranscriber)
  - Neither the docs nor the iOS 27.1 Speech swiftinterface mention background restrictions (local SDK grep found no "background" mentions).
- **Background audio mode**: intended for audio playback, e.g. music players. Using it for other purposes violates guidance — [Quinn 685525](https://developer.apple.com/forums/thread/685525). App Review 2.5.4: "Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Inferences
- **Recommended tiering for FreeBee**:
  - (a) BLE wake path, always: decrypt (AES-CTR is microseconds per packet), reassemble ADTS, append raw ADTS to a segment file, update an index. Optionally run a cheap energy-based VAD on decoded PCM, or defer decoding entirely.
  - (b) Foreground: catch-up transcription of new segments with SpeechTranscriber or WhisperKit/Core ML, search UI, summaries.
  - (c) User taps "Process now": BGContinuedProcessingTask with honest `Progress` (segments done / total) so iOS doesn't expire it. CPU/ANE only on iPhone, so expect slower throughput.
  - (d) Nightly: BGProcessingTask with `requiresExternalPower = true` (disables the CPU monitor) for bulk STT, diarization and Foundation Models summaries.
  - Make every stage resumable per segment, per WWDC guidance on incremental progress.
- BGContinuedProcessingTask cannot be auto-scheduled for "always-on" use. WWDC explicitly warns against automatic workloads, and the system may cancel them. It is a per-user-action tool.
- Live Activities by themselves do not grant execution time (not found stated by Apple). The Live Activity UI for continued tasks is system-provided. A custom Live Activity for "Recording" status is a UI and consent affordance only.
- Because background GPU is unavailable on iPhone, MLX/Metal-based Whisper or LLMs will degrade sharply in the background. Prefer Core ML models that can run on CPU+ANE (e.g. WhisperKit Core ML builds), or Apple's SpeechTranscriber (system-managed), for background or continued tasks. Verify ANE behaviour empirically.

### Gaps
- No Apple statement on whether SpeechTranscriber/SpeechAnalyzer runs while the app is merely BLE-woken in the background, or whether it counts against the CPU monitor (the model work may happen in a system process). Test on device.
- No Apple statement on Neural Engine availability or throttling for background apps or continued tasks.
- Whether iPhone 17 Pro on iOS 27 reports `.gpu` in `BGTaskScheduler.shared.supportedResources` is unknown. Check at runtime on the user's device. The DTS "not on iPhone" answer is from Nov 2025 (iOS 26).
- No numeric Foundation Models background rate-limit published.

## 3. BLE throughput / connection parameters / reliability for streaming audio on iPhone

### Takeaway
32 kbps (≈4 kB/s) is far below even pessimistic iPhone BLE throughput, so raw bandwidth is not the problem. The priorities are link stability, power, and gap-aware reassembly. The peripheral, not the app, negotiates connection parameters within Apple's Accessory Design Guidelines (min interval 15 ms, multiples of 15 ms). DLE (251-byte PDUs), large ATT MTU and 2M PHY reduce radio-on time. Reliability comes from the sequence number, ADTS resync after gaps, immediate non-timing-out reconnect, and "ready only when fresh frames arrive" watchdogs.

### Cited Findings
- **Apple DTS (Argun Tekant, Jan 2025)**:
  - On connection parameters, the accessory negotiates them: "There is nothing you can do in an app that will change those."
  - Apple's Accessory Design Guidelines rules as summarized in the reply:
    - Peripheral Latency ≤ 30 intervals
    - Interval Min ≥ 15 ms, ≤ 2 s, and a multiple of 15 ms
    - Interval Max at least 15 ms greater than Interval Min, or both equal 15 ms
    - Supervision timeout range as summarized: 6–18 s (see Gaps)
  - 7.5 ms is rejected, and rejected requests fall back to defaults. Acceptance is not guaranteed even when compliant.
  - Throughput levers: Extended Data Length (251 bytes), larger MTU, LE 2M PHY, Write Without Response, and L2CAP CoC, which "will dramatically increase your throughput by reducing GATT protocol overhead".
  - [Apple Developer Forums 773555](https://developer.apple.com/forums/thread/773555)
- **Community reports in that thread**: ~5 packets per connection event on iPhones. An A16 iPad on iPadOS 18 processed one packet per event (~8 kB/s). Another iPadOS 18 report showed one transmission per 30 ms interval with More Data = false. — [forums 773555](https://developer.apple.com/forums/thread/773555)
- **The phone may counter-propose parameters**: a 30 ms interval is sometimes offered instead of 15 ms to save power — [Apple Developer Forums 756572](https://developer.apple.com/forums/thread/756572). The central picks parameters and can reject peripheral update requests; Apple ADG §49.6 sets a 15 ms minimum vs. 7.5 ms in the Bluetooth spec — [Silicon Labs, Selecting suitable connection parameters for Apple devices](https://docs.silabs.com/mobile-apps/3.3.1/mobile-apps-suitable-connection-parameters/)
- **Omi failure modes to design against** — [omi #11307](https://github.com/BasedHardware/omi/issues/11307):
  - Background `connection_timeout` at weak RSSI
  - A 200 ms delayed first reconnect
  - Reliance on restoration callbacks
  - Reconnect storms without backoff draining battery
  - Firmware not re-arming the mic after disconnect
  - The rule "connection is not readiness until fresh frames arrive"

### Inferences
- **Bandwidth math**: ~4,000 B/s payload over ~8.1 notifications/s ≈ 490 B per notification. The existing link already carries ~494-byte notifications (4-byte seq + ciphertext), which implies a negotiated ATT MTU ≥ ~497. With DLE, each notification spans ~2 LL PDUs. Even the worst iPad report (~8 kB/s) is 2x the requirement. The phone app cannot change the connection interval. Only Bee firmware can request parameters, and we are not modifying firmware. So there is nothing to tune app-side except avoiding extra GATT traffic (e.g. battery polls; Omi polled every 5 s).
- **Reliability design for FreeBee**:
  1. Track the uint32 seq. On a jump, record a gap of (Δseq × ~123 ms) in the timeline index.
  2. Each packet decrypts independently (IV = nonce‖seq), but ADTS frames straddle packets (~1.9 frames/packet). After a gap, discard the partial frame and resync on the next ADTS syncword (0xFFF) with header validation. The Mac `AdtsReassembler` already does false-sync skipping.
  3. On disconnect, call `connect()` immediately with no delay (it never times out), then re-open the session and re-subscribe on `didConnect`. Back off only the *session/command* retries, not the pending connect.
  4. Use a watchdog: if subscribed but no audio for N seconds, re-issue SetDeviceState(recording) or re-open the session.
  5. Treat a new nonce or session as a new stream: reset the 3-frame discard and the reassembler.
  6. Persist per-segment metadata (start wall-clock, first/last seq, gaps) so downstream STT can align timestamps.
- L2CAP CoC would be more efficient, but the Bee only exposes GATT notify. That is not applicable without firmware changes.

### Gaps
- Supervision timeout range: the DTS summary rendered it as "6 to 18 seconds". I could not fetch the current ADG text to confirm, and older ADG editions are commonly quoted with different values. Verify in the ADG §"Connection Parameters" before relying on it.
- I found no Apple-published typical/maximum ATT MTU for iPhone 17 Pro on iOS 27. Read it on device via `peripheral.maximumWriteValueLength(for:)` (write side only) and the observed notification sizes.
- No public data on which connection interval or PHY Bee firmware 0.6.1 requests. Inspecting with PacketLogger (Bluetooth logging profile) on the iPhone would answer this.

## 4. Decoding on iOS (AAC-ADTS, Opus) and AES-128-CTR

### Takeaway
AAC-ADTS decoding is native via AudioToolbox: `AudioFileStream` (`kAudioFileAAC_ADTSType`) to parse packets, then `AudioConverter`/`AVAudioConverter` to PCM. Opus decoding is also built into AudioToolbox (`kAudioFormatOpus`, since iOS 11) via `AVAudioConverter`. A local test on macOS 27 created converters at 8/12/16/24/48 kHz, but packet-loss concealment isn't exposed. `libopus` (e.g. swift-opus) is the fallback. CryptoKit has no CTR, but CommonCrypto has `kCCModeCTR` (big-endian 128-bit counter) in the iOS 27.1 SDK, and swift-crypto's `CryptoExtras` provides `AES._CTR` with 12- or 16-byte nonces. Either matches the Bee's IV = nonce(12)‖seq(4) scheme.

### Cited Findings
- `kAudioFormatOpus`: "A key that specifies the Opus codec", available iOS 11.0+ (macOS 10.13+) — [kAudioFormatOpus docs](https://developer.apple.com/documentation/coreaudiotypes/kaudioformatopus). It is still present in the iPhoneOS27.1 SDK `CoreAudioTypes/CoreAudioBaseTypes.h` (`kAudioFormatOpus = 'opus'`).
- **Apple engineer accepted answer**: full PCM↔Opus encode/decode with `AVAudioConverter`. It uses 48 kHz mono, `mFramesPerPacket = 960`, wraps each Opus packet in an `AVAudioCompressedBuffer` (packetCapacity 1, with `packetDescriptions[0].mDataByteSize` set), and references TN3136 — [Apple Developer Forums 763362](https://developer.apple.com/forums/thread/763362); [TN3136: AVAudioConverter sample rate conversions](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)
- **Opus packet-loss concealment**: a developer asks how to signal packet loss to the AVAudioConverter Opus decoder (libopus supports NULL-packet PLC), and the thread has no accepted answer — [Apple Developer Forums 699929](https://developer.apple.com/forums/thread/699929). `swift-opus` wraps libopus and decodes packets to `AVAudioPCMBuffer` — [swift-opus](https://swiftpackageregistry.com/alta/swift-opus)
- **Local empirical check (this machine, macOS 27.0.1, same AudioToolbox codebase as iOS but not an iOS test)**: `AVAudioConverter(from: Opus ASBD, to: Float32 PCM)` returned non-nil at 8000, 12000, 16000, 24000 and 48000 Hz (20 ms packets). AAC (`kAudioFormatMPEG4AAC`, 16 kHz, 1024 frames/packet) → PCM converter also created. `kAudioFormatProperty_Decoders` reports 1 Opus decoder. Converter creation does not prove a successful decode of Bee-produced Opus packets. — test script /tmp/bee_opus_test/t.swift (run 2026-10-20)
- **CommonCrypto (iPhoneOS27.1 SDK `usr/include/CommonCrypto/CommonCryptor.h`)**: `kCCModeCTR = 4` and `kCCModeOptionCTR_BE` ("now only Big Endian mode is supported"), used via `CCCryptorCreateWithMode`. This is a big-endian, full 128-bit counter, which matches Python `cryptography` `modes.CTR(16-byte IV)` as used in `mac/src/beekit/audio.py` (`modes.CTR(nonce + packet[:4])`).
- **swift-crypto**: `AES._CTR.encrypt/decrypt(_:using:nonce:)`. `AES._CTR.Nonce(nonceBytes:)` accepts 12 bytes (96-bit nonce + 32-bit counter starting at 0) or 16 bytes (a full 128-bit initial counter block). The implementation is BoringSSL-backed (`typealias AESCTRImpl = OpenSSLAESCTRImpl`). The package exposes both `_CryptoExtras` and `CryptoExtras` library products. Latest release is 5.0.3, published 2026-10-20. — [swift-crypto AES_CTR.swift](https://github.com/apple/swift-crypto/blob/main/Sources/CryptoExtras/AES/AES_CTR.swift); [swift-crypto Package.swift](https://github.com/apple/swift-crypto/blob/main/Package.swift); [swift-crypto releases](https://github.com/apple/swift-crypto/releases)

### Inferences
- **For Bee**: pass the full 16-byte IV (nonce‖seq_BE) to either API. With CommonCrypto, `CCCryptorCreateWithMode(kCCDecrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, iv, key, 16, nil, 0, 0, kCCModeOptionCTR_BE, &ref)` per packet, or per stream if you `CCCryptorReset` with a new IV. With swift-crypto, `AES._CTR.Nonce(nonceBytes: iv16)`. CommonCrypto avoids a BoringSSL dependency (binary size, build time) and is system-provided. Prefer it for BeeKit. There is no auth tag, so integrity can only be sanity-checked via ADTS syncword/CRC.
- **AAC path**: feed decrypted bytes to `AudioFileStreamOpen(..., kAudioFileAAC_ADTSType)` → `AudioFileStreamParseBytes`. Packets arrive in the packets callback with ASPDs, and you feed them to `AVAudioConverter` (AAC→Float32/Int16 16 kHz). Alternatively, parse ADTS yourself (the Mac `AdtsReassembler` logic ports directly): strip the 7/9-byte header and build `AVAudioCompressedBuffer`s with `mFramesPerPacket = 1024`. Converting to 16 kHz mono Float32 directly suits Whisper/SpeechAnalyzer input.
- **Opus (codec 0 on the Bee)**: AVAudioConverter likely works at the Bee's rate, but PLC requires libopus. Since the device is on AAC (codec 1) and that path is proven, keep AAC and treat Opus as optional.

### Gaps
- Not verified on an iOS device that AudioToolbox decodes Bee Opus packets correctly at 16 kHz, or how it handles Opus framing without an Ogg/CAF container.
- Not verified whether `AudioFileStream` handles ADTS with CRC (protection_absent = 0). Check Bee headers.

## 5. Storage: background writes while locked, disk budget, phone battery

### Takeaway
Write compressed ADTS segments (e.g. 5–15 min files) under `FileProtectionType.completeUntilFirstUserAuthentication`, so writes keep working when the phone is locked (after the first unlock since boot). Never use `.complete` for capture files. 32 kbps is ~14.4 MB/hour, ~230 MB per 16-hour day, ~7 GB per 30 days. Decoded PCM is 8x larger, so don't store it. There is no clean public number for phone-side battery cost. Omi's 51%/16 h figure is confounded by an audio-session keep-alive and polling.

### Cited Findings
- `.completeUntilFirstUserAuthentication`: "cannot be accessed until after the device has booted. After the user unlocks the device for the first time, your app can access the file and continue to access it even if the user subsequently locks the device." — [FileProtectionType.completeUntilFirstUserAuthentication](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication)
- After a reboot, Bluetooth-restored apps are not relaunched until first unlock — [TN3115 note 4](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules). The BackgroundTasks header uses `NSFileProtectionCompleteUntilFirstUserAuthentication` as the default for data needed by background health-research tasks — local iPhoneOS27.1 SDK `BGTaskRequest.h` (`BGHealthResearchTaskRequest.protectionTypeOfRequiredData`).
- Jetsam can kill background apps for `vnode-limit` (too many open files system-wide) or `fc-thrashing` (non-sequential memory-mapped file I/O) — [jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)
- **Battery data point (Omi, iOS 26.6, iPhone 15 Pro Max)**: iOS attributed 51% of battery to the app over 16 h in background. Suspected causes: active audio session, foreground task, 5 s battery poll, reconnects without backoff — [omi #11307](https://github.com/BasedHardware/omi/issues/11307)
- Apple: "radio usage has an adverse effect on an iOS device's battery life—try to minimize the amount of work you do in the background" — [archived Core Bluetooth guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)

### Inferences
- **Disk budget at 32,000 bit/s = 4,000 B/s**:

  | Period | Size |
  |---|---|
  | 1 h | 14.4 MB |
  | 16 h | 230 MB |
  | 24 h | 346 MB |
  | 30 × 16 h | ~6.9 GB |
  | 365 × 16 h | ~84 GB |

  ADTS headers add ~7 B × 15.6 frames/s ≈ 109 B/s (~2.7%). 16 kHz/16-bit PCM would be 32,000 B/s (115 MB/h), so keep audio compressed and decode on demand. Apply VAD-based retention, e.g. delete non-speech segments after transcription, to cut storage substantially.
- **Write pattern**: one open `FileHandle` per active segment, sequential appends, `synchronize()` every ~N seconds or per segment close, roll over every 5–15 min. Store the index (seq ranges, gaps, timestamps) in SwiftData/SQLite, also with `completeUntilFirstUserAuthentication`. That matters especially for SQLite WAL files, which must be writable while locked. Exclude raw audio from iCloud backup if desired (`isExcludedFromBackup`) for privacy and size.
- Phone-side battery for the BLE link alone is probably modest (8 small notifications/s). The dominant costs will be wakeups doing extra work, reconnect storms, and any keep-alive audio session. Measure with Xcode Organizer energy logs / MetricKit (`MXCPUMetric`, `MXCPUExceptionDiagnostic`) on the user's device.

### Gaps
- No primary-source measurement of iPhone battery drain from sustained BLE notifications at ~8/s and ~4 kB/s.
- Not verified whether SwiftData's default store uses a protection class compatible with locked background writes. Check `NSPersistentStoreFileProtectionKey` / the default class (apps default to `completeUntilFirstUserAuthentication` unless an entitlement overrides it; not re-verified here).

## 6. App Store / privacy requirements and legal consent for always-on recording

### Takeaway
BLE audio from an external mic does not trigger iOS's microphone indicator or microphone permission. App Review 2.5.14 still requires explicit consent and a clear visual or audible indication while recording. Background-mode misuse (e.g. `audio` keep-alive) violates 2.5.4. FreeBee is a personally side-loaded app, so App Review doesn't gate it, but the same UX (session-based start/stop, visible recording state) is good practice. Legally, US federal law and ~38 states are one-party consent. About 11 states (incl. California, Florida, Illinois, Maryland, Massachusetts, Montana, New Hampshire, Pennsylvania, Washington, Delaware, Nevada) require all-party consent, and an always-on ambient recorder captures third parties who haven't consented.

### Cited Findings
- **App Review 2.5.14**: "Apps must request explicit user consent and provide a clear visual and/or audible indication when recording, logging, or otherwise making a record of user activity. This includes any use of the device camera, microphone, screen recordings, or other user inputs." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **App Review 2.5.4**: background services only "for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **App Review 5.1.1(viii)**: "Apps that compile personal information from any source that is not directly from the user or without the user's explicit consent … are not permitted." — [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- **Apple Core Bluetooth guidance**: apps "should be session based and provide an interface that allows the user to decide when to start and stop the delivery of Bluetooth-related events" — [archived Core Bluetooth guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- **Usage strings, as Omi does it**:
  - `NSBluetoothAlwaysUsageDescription` explaining wearable mic streaming
  - `NSSpeechRecognitionUsageDescription` "to convert your speech to text for processing on your device"
  - `NSMicrophoneUsageDescription` only for the phone mic
  - [omi Info.plist](https://github.com/BasedHardware/omi/blob/main/app/ios/Runner/Info.plist)
  - AccessorySetupKit removes the need for the global Bluetooth permission prompt for ASK-paired accessories, and apps keep using Core Bluetooth after setup — [Meet AccessorySetupKit, WWDC24](https://developer.apple.com/videos/play/wwdc2024/10203/) (per search summary; not re-fetched)
- **Recording consent (secondary sources, not statutes)**:
  - Federal law and ~38 states + DC are one-party consent. The commonly cited all-party list is California, Delaware, Florida, Illinois, Maryland, Massachusetts, Montana, Nevada, New Hampshire, Pennsylvania, Washington.
  - Connecticut and Michigan are disputed edge cases, and Nevada differs for phone vs. in-person.
  - In multi-state settings the strictest law is often applied, and California asserts reach over calls involving a Californian.
  - [Scribbl 2026 state guide](https://scribbl.co/post/do-you-have-to-tell-people-youre-recording); [Layer3 Labs, two-party consent states (updated Aug 2026)](https://www.layer3labs.io/guides/two-party-consent-states)

### Inferences
- The iOS orange/green privacy indicator covers only the device's own mic and camera, so BLE audio shows nothing system-side. FreeBee should provide its own persistent indication: an in-app recording banner, an optional Live Activity / Dynamic Island "Recording" status, and use of the Bee's LED/states. That satisfies 2.5.14's spirit if ever distributed.
- If FreeBee uses Apple's Speech framework (SpeechTranscriber), include `NSSpeechRecognitionUsageDescription`. On-device WhisperKit/Core ML needs no extra permission string.
- All-day ambient capture records bystanders. Even in one-party states, the "party to the conversation" rationale is weak for conversations the wearer isn't in. Provide quick mute (Bee double-press/hold events A001/A002 → mute) and retention controls. This is not legal advice.
- Personal side-loading via Xcode means App Review rules don't gate FreeBee today. Development-signed builds need periodic re-signing (not sourced here).

### Gaps
- No Apple App Review precedent found specifically for third-party BLE-wearable always-on recorders. Omi is on the App Store with `audio`+`voip`+`location` background modes, but its review history isn't public.
- No primary statute citations collected. Non-US jurisdictions (EU GDPR/ePrivacy, Canada, etc.) not covered.
