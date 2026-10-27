# Follow-up 2: Which inference engines run while FreeBee is backgrounded or locked on iOS 27.0.1 (ANE/Core ML, SpeechAnalyzer, Foundation Models, BGProcessingTask)

Scope note: Apple's iOS 27 release notes, entitlement docs and the iPhoneOS27.1 SDK headers in the local Xcode 27.1 were read directly (docs via Apple's JSON doc endpoints). No source has on-device measurements for iOS 27.0.1 on an iPhone 17 Pro. Everything below marked "inference" or listed under Gaps has to be confirmed with a probe on the user's phone.

## 1. Does Core ML Neural Engine inference (Parakeet, Silero, pyannote) run when the app is BLE-woken in the background on iOS 27.0.1?

### Takeaway
Not without a new entitlement. In iOS 27 Apple deliberately restricts background Neural Engine access "similar to GPU usage restrictions". Any ANE access while the app is in the background now requires `com.apple.developer.background-tasks.continued-processing.inference`, whatever the API (Core ML, Core AI or MPSGraph) and whether or not a continued-processing task is running. FreeBee's entitlements file doesn't have it. The Seed 1 "broken" report in forum 832048 was this restriction, not a bug. Nobody has published what an un-entitled app sees (an error or a silent CPU fallback), or any CPU-only real-time factor on iPhone, so both must be measured.

### Cited Findings
- iOS & iPadOS 27 Release Notes, Core AI → New Features (official): "iOS 27 includes Neural Engine improvements for Apple Intelligence capable devices. **The system now restricts background access to the Neural Engine, similar to GPU usage restrictions.** Large model loading (over 1 GB) performance is improved on the Neural Engine. **Neural Engine memory usage is now attributed to your app process instead of the system**, and appears in the Allocations instrument. (174796039) **Access to the Neural engine when your app is in the background requires the new entitlement: 'com.apple.developer.background-tasks.continued-processing.inference'.** (179282606)" — [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- A beta 3 release-notes diff shows the change was planned. The earlier known issue "You cannot access the Neural Engine when your app is in the background. (179282606) Workaround: Restrict your models to CPU only or prefer GPU with the appropriate Background GPU Access entitlement" was removed and replaced by the entitlement requirement. Same radar number. — [iOS 27 + macOS 27 Beta 3 release-notes diff (galenguyer gist)](https://gist.github.com/galenguyer/eef52cf39cbb7745fe98f2e32f453590)
- The entitlement page "Background Inference" (iOS/iPadOS/macOS/tvOS/visionOS/watchOS 27.0+) describes a Boolean, default `NO`: "An entitlement that lets a background task run inference on the Neural Engine. This entitlement works with BGContinuedProcessingTask, which lets your app's critical inference work finish on the Neural Engine even when your app moves to the background before the task completes. **The system also requires the entitlement for any Neural Engine access while your app is in the background, regardless of whether it's running a continued background task. You can perform inference with Core AI, Core ML, or Metal Performance Shaders Graph.**" — [Apple: Background Inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference)
- The page does not say how to obtain the entitlement. The sibling GPU entitlement's docs do: "enable the Background GPU Access capability on your app's target." — [Apple: Resources.gpu](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu)
- Forum 832048 (June 2026): OP atilaa wrote: "In iOS 26, Core ML reliably submits inference requests targeting the Neural Engine in the background. In iOS 27 Seed 1, this capability is currently broken." The only Apple Staff reply, marked recommended, covered compute preference only: "With Core AI, I believe you can express a preference for NeuralEngine but it's up to Core AI." The OP replied "The question was primarily about background capability." There are no later updates on the page. — [Apple Developer Forums 832048](https://developer.apple.com/forums/thread/832048)
- Apple's long-standing Core ML guidance: "Use `cpuOnly` to restrict the model to the CPU, if your app might run in the background or runs other GPU intensive tasks." — [Apple: MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits)
- iOS 27 resolved issue showing Core AI can quietly move work off the ANE for unsupported configurations (unrelated to background): "Fixed: Certain weight and activation configurations may not run on the Neural Engine, such as FP8-quantized weights … Affected models may run on the CPU or GPU instead. (176210080)" — [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
- FreeBee's `Support/Bee.entitlements` has only `com.apple.security.application-groups`. It has no background-inference, background-GPU or data-protection entitlement. The app's `UIBackgroundModes` is `bluetooth-central`. — local files `app/FreeBee/Support/Bee.entitlements`, `Support/Bee-AccessorySetupKit.plist`
- In the iPhoneOS27.1 SDK headers the only mention is `continued-processing.gpu` (BGTaskRequest.h). `continued-processing.inference` appears nowhere, which is normal because entitlements are keys, not SDK symbols. The joeblau/voice spike claimed the inference entitlement "does not exist in the iOS 27.2 SDK". That probably reflects the same header search, not an absent entitlement. — local `iPhoneOS27.1.sdk/.../BackgroundTasks.framework/Headers/BGTaskRequest.h`; [joeblau/voice PR #112](https://github.com/joeblau/voice/pull/112)
- Production projects reacting to the change:
  - joeblau/voice merged PR #112 on Oct 7, 2026. It steps a stage from Neural Engine to CPU to SpeechTranscriber off-screen on "two errors in a row, or a p95 above 80% of a stage's budget". It reloads Silero on `.cpuOnly` mid-stream, keeping LSTM state (Mac test: "max difference 0.0"). The author: "What iOS 27 actually does to Neural Engine work off screen is still unmeasured … the shipped mitigation is provisional." Testing used simulators, Mac and fakes only. — [joeblau/voice PR #112](https://github.com/joeblau/voice/pull/112), [issue #26](https://github.com/joeblau/voice/issues/26)
  - Heey-Global/verity raised its minimum target to iOS 27 (Sep 30, 2026) because "its background inference entitlement is available from iOS 27". Signing and provisioning were still unverified. — [verity PR #930](https://github.com/Heey-Global/verity/pull/930)
- Pre-iOS-27 background GPU context: DTS (Nov 2025) said background GPU "won't help on the iPhone (it's not available there)". In the same thread, a `.cpuAndNeuralEngine` Core ML workload ran 4–5x slower in a background BGContinuedProcessingTask. — as recorded in `ios_ble_background_streaming.md`; [Forums 807957](https://developer.apple.com/forums/thread/807957)
- The CPU monitor kills background processes over "80% cpu over 60 seconds" (forum 690666). Only `BGProcessingTaskRequest.requiresExternalPower = YES` disables it. — `ios_ble_background_streaming.md`; [Forums 690666](https://developer.apple.com/forums/thread/690666); local SDK `BGTaskRequest.h`

### Inferences
- Without the entitlement, assume FluidAudio Parakeet, Silero and pyannote get no ANE while FreeBee is BLE-woken in the background on iOS 27.0.1. With the entitlement, the docs say background ANE access is permitted. The entitlement name ("continued-processing") and the first sentence of the doc tie it mainly to BGContinuedProcessingTask, so it is unclear whether a plain `bluetooth-central` wake also gets the ANE. The second sentence suggests the entitlement gates all background ANE use.
- Error or silent fallback: no source answers this. Some circumstantial evidence points to an error or a hang rather than a silent CPU fallback:
  - In 832048 the OP called it "broken".
  - Apple's beta workaround was to restrict models to the CPU yourself, which would be pointless if Core ML fell back on its own.
  - joeblau designed for "errors".

  Treat this as unconfirmed. Code should handle both an error and a sudden slowdown (watch p95 latency, as joeblau does).
- ANE memory is now charged to our process. A 445–595 MB Parakeet encoder resident in the background therefore counts against FreeBee's own background memory budget, which raises jetsam risk on top of the ANE gate.
- Practical plan for real-time background work, from most to least supported:
  - Silero VAD on `.cpuOnly`. It is tiny, and Apple's guidance favours CPU in the background.
  - Capture and store AAC.
  - Request the Background Inference entitlement and test it.
  - Otherwise defer Parakeet and pyannote to the foreground, or to on-charger tasks that run with the entitlement (see Q4).
- A CPU-only Parakeet pass in the BLE-background path will probably hit the 80%/60 s CPU monitor, because the background is on battery and no requiresExternalPower exemption applies. Even if CPU RTF is acceptable, run CPU-heavy ASR only in bursts. This is inferred from the CPU-monitor rule, not measured.

### Gaps
- No iOS 27.0.1-specific release notes or forum reports. No public report of what Core ML returns (error code, hang, or CPU fallback) when an un-entitled background app targets `.all`/`.cpuAndNeuralEngine`.
- No published iPhone RTF for FluidAudio Parakeet, Silero or pyannote on `.cpuOnly`, on any iOS version. FluidAudio's benchmarks are ANE/Mac. The user needs a probe on the iPhone 17 Pro: the same 10-min clip in foreground ANE, foreground `.cpuOnly`, background (BLE-woken) `.all`, and background `.cpuOnly`, logging wall time, thrown errors, MetricKit CPU, and `os_signpost` per inference.
- Unknown whether the Background Inference entitlement is self-service (an Xcode capability) or managed (requires an Apple request). Unknown whether it is honoured outside BGContinuedProcessingTask in a `bluetooth-central` wake.

## 2. Does SpeechAnalyzer/SpeechTranscriber accept AnalyzerInput and return results while backgrounded or locked? Whose CPU does it use? Can AssetInventory un-reserve the asset while we're in the background?

### Takeaway
Apple documents none of this. No developer has published a device test on iOS 27 either; joeblau's SpeechTranscriber fallback is merged but untested on hardware. On macOS 27, Speech recognition runs in a separate XPC service process (`localspeechrecognition`), which supports, but does not prove, the "system-managed, out-of-process" model on iOS. Asset unsubscription is triggered by non-use, not by our app being backgrounded.

### Cited Findings
- SpeechAnalyzer docs:
  - Without `finish`, the analyzer "won't terminate its result streams and will wait for additional audio input sequences or buffers".
  - "The system normally limits simultaneous analyses to a conservative number … If you exceed that number, the system throws an `insufficientResources` error."
  - The docs say nothing about background, lock state or process model.

  — [Apple: SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- AssetInventory docs:
  - Assets are "machine-learning models downloaded from Apple's servers and managed by the system … the system retains and updates it automatically, and shares it with other apps."
  - "The system may unsubscribe your app from assets that haven't been used in a while."
  - "When your app no longer needs assets for a particular locale, call `release(reservedLocale:)` … The system will remove the assets at a later time."

  — [Apple: AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- `release(reservedLocale:)`: "Removes an asset locale reservation … Unsubscribes from any assets that depended on the locale." — [Apple: release(reservedLocale:)](https://developer.apple.com/documentation/speech/assetinventory/release(reservedlocale:)). The iOS 27.1 SDK exposes `maximumReservedLocales`, `reservedLocales`, `reserve(locale:)` and `release(reservedLocale:)`, with nothing background-specific. — local `Speech.framework/.../arm64e-apple-ios.swiftinterface`
- Local observation on this Mac (Darwin 27.0, macOS 27): `ps` shows several `/System/Library/Frameworks/Speech.framework/Versions/A/XPCServices/localspeechrecognition.xpc/.../localspeechrecognition` processes, plus `corespeechd`, `speechmaintenanced` and the `com.apple.speech.speechdatainstallerd` launch agent. Speech recognition on macOS is therefore out of process. — local `ps -axo pid,comm`, `/System/Library/LaunchAgents`
- joeblau/voice PR #121 (merged Oct 7, 2026) adds a SpeechAnalyzer/SpeechTranscriber fallback. In the PR's words, "The code is done and unit-tested, but it is not verified on a device." The locked-phone case is listed as pending. Tests ran on "temporary iPhone 17 Pro simulators (iOS 26.5 and iOS 27.0)". A reviewer warned that a background switch "can therefore start an `AssetInventory` download at exactly the wrong moment." — [joeblau/voice PR #121](https://github.com/joeblau/voice/pull/121)
- The iOS 27 release notes have no Speech-framework entries about background, lock or ANE. Speech-adjacent notes fall under "Dictation" only. — [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)

### Inferences
- The likely iOS architecture mirrors macOS: our process streams `AnalyzerInput` buffers over XPC, and a system service runs the model on its own CPU/ANE budget. If so:
  - the model's CPU time would not count against FreeBee's CPU-monitor budget (only our buffer conversion and IPC would);
  - Apple's new background-ANE gate applies to "your app", and probably not to a system daemon working for a background client.

  This is the strongest argument for SpeechTranscriber as the background engine. It is inference from the macOS process layout, not documented for iOS.
- Asset un-reserve: Apple only says unused assets "may" be unsubscribed and that our own `release` call frees a reservation. Nothing suggests un-reservation because of backgrounding. Still, check `AssetInventory.status(forModules:)` before each background session, because an install/download is an async network operation that may not complete in the background.
- The best-supported practical answer: SpeechTranscriber is the most plausible near-real-time background ASR on iOS 27 without special entitlements, but it is unproven. Verify with a probe: lock the phone, feed 10 min of decoded Bee PCM through `AnalyzerInput`, and log result timestamps, thrown errors and MetricKit CPU for our process.

### Gaps
- No Apple statement or device report on SpeechTranscriber with the app backgrounded (kept alive by `bluetooth-central`) or the device locked, on iOS 26 or 27.
- The iOS process model for SpeechAnalyzer and its CPU accounting are unconfirmed. The macOS evidence is indirect.
- No source on whether SpeechTranscriber's own ANE use is affected by the iOS 27 background-ANE restriction.

## 3. Is Foundation Models usable in the background on battery on iOS 27? What does LanguageModelError.rateLimited mean now? Does it answer while locked?

### Takeaway
Apple's own iOS 27 statement (June 2026): background requests "might be throttled or canceled", and no entitlement raises priority. The iOS 26 detail "only when in background AND on battery" has not been restated for iOS 27. `LanguageModelError.rateLimited` is now one error type shared by all `LanguageModel` providers and carries an optional `resetDate`. The daily-quota behaviour developers report ("786 generations", "count=500 over 86400 s") is from Private Cloud Compute, which FreeBee must not use anyway. No source covers locked-device behaviour.

### Cited Findings
- iOS 26 doc for the now-deprecated case: "This error will only happen if your app is running in the background and exceeds the system defined rate limit." — [Apple: GenerationError.rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:))
- The iOS 27.1 SDK marks `GenerationError.rateLimited` `@available(iOS, deprecated: 27.0, message: "Use LanguageModelError/rateLimited(_:) instead.")`. The new `LanguageModelError.RateLimited` struct has `resetDate: Date?`, `debugDescription` and `metadata`. `concurrentRequests` moved to `LanguageModelSession.Error`, and `assetsUnavailable` moved to `SystemLanguageModel.Error`. — local `FoundationModels.framework/.../arm64e-apple-ios.swiftinterface` (lines ~1527–1566, 2026–2028, 3559–3566)
- iOS 27 doc: "The session has been rate limited. This failure can happen if you make too many requests in a short window. You can recover from this error by spacing your requests or reducing system load. The exact solution may be model dependent." No mention of background or battery. — [Apple: LanguageModelError.rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/ratelimited(_:))
- Apple Frameworks Engineer, June 2026: "On iOS, we might limit access to the model on background tasks… excessive requests to the model made in the background might be throttled or canceled." — [Forums 833642](https://developer.apple.com/forums/thread/833642) (as quoted in `on_device_llm_summarization.md`; not re-fetched)
- Apple Frameworks Engineer, June 2026: the OS manages on-device LLM requests "automatically, based on the system conditions (like thermals)". No entitlement or API raises priority. — [Forums 833666](https://developer.apple.com/forums/thread/833666) (via prior note)
- iOS 26 era: "Rate limiting applies when your device is on battery AND when your process is running in the background." Also, don't stream responses in the background. — [Forums 789788](https://developer.apple.com/forums/thread/789788)
- PCC is where the daily-quota behaviour lives:
  - Thread 843046 (Aug 2026, macOS 27 beta): `LanguageModelError.rateLimited` hit at "cumulative generation **786** for the day". Recovery came somewhere in "(41 minutes, 19.98 hours]". `quotaUsage` read `belowLimit` and `resetDate = nil` even while blocked.
  - In the same thread, Apple Designer: "it's up to each server model provider to decide when to rate limit. I wouldn't assume a fixed number". DTS asked for a feedback report.
  - An Oct 16, 2026 post reports `PrivateCloudComputeLanguageModel.Error.quotaLimitReached` after ~450 requests.

  — [Forums 843046](https://developer.apple.com/forums/thread/843046)
- Thread 849570 (iOS 27 public): "InferenceError::rateLimited::PrivateCloudComputeError: deniedDueToUserDeviceRateLimit". A daemon log shows "rate limit discovered: count=500, duration=86400". The poster says the budget is shared with Siri AI and HomeKit PCC features. The behaviour persists on 27.2 RC. There is no Apple reply. — [Forums 849570](https://developer.apple.com/forums/thread/849570)
- Local observation on macOS 27: on-device model inference runs in `/System/Library/ExtensionKit/Extensions/TGOnDeviceInferenceProviderService.appex`, with `/usr/libexec/modelmanagerd` and `generativeexperiencesd` alongside. So it is out of process, at least on macOS. — local `ps`
- iOS 27 resolved issue: "When using the on-device Apple Foundation Model for both tool calling and guided generation, some prompts might cause the model to call tools excessively. (177748926)" — [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)

### Inferences
- In practice, `rateLimited` on the on-device `SystemLanguageModel` should be read as Apple's background/battery/system-load throttle. It is transient: back off, re-queue, and prefer non-streaming `respond`. On PCC it means a per-user/device daily quota, which FreeBee should never touch under the no-cloud rule.
- Code must never instantiate `PrivateCloudComputeLanguageModel`. Also confirm that no "automatic" model routing sends requests to PCC; the prior note's `LanguageModel` protocol makes this a code-review item.
- Foundation Models inference probably runs in a system extension, like Speech. So the iOS 27 background-ANE entitlement gate on "your app" probably does not block it, but throttling still applies. The best-supported plan:
  - Run short `@Generable` extraction per closed conversation when the app happens to be alive, catching `rateLimited`/cancellation and persisting a queue.
  - Do the bulk summaries on charger (Q4) or in the foreground.
- "FM reliably usable in background" (prior LLM note) overstates the case. "Usable but throttled or cancellable in the background; best-effort" is what Apple has said.

### Gaps
- No Apple statement for iOS 27 on whether on-device FM rate limiting still requires both background and battery, or now also applies on power.
- No source on whether `SystemLanguageModel` answers while the device is locked (Data Protection on model assets or Apple Intelligence state). It needs a device probe: lock, wait over 10 s, call `respond` from a BLE-woken handler, and log the result or error type.
- `resetDate` semantics for on-device throttling are undocumented. Thread 843046 shows it `nil` even when blocked on PCC.

## 4. BGProcessingTask with requiresExternalPower=true on iOS 27: how often, how long, which engines while locked, and does supportedResources contain .gpu on iPhone 17 Pro?

### Takeaway
Apple guarantees no frequency or duration. The iOS 27.1 SDK says the system tries "within the next two days as long as the user has used your app within the past week". DTS says these tasks "typically" run overnight, and on-power tasks get the CPU monitor disabled. Under iOS 27, ANE use inside a BGProcessingTask needs the Background Inference entitlement too, because Apple says it applies "regardless" of task type. `supportedResources` and `.gpu` apply only to `BGContinuedProcessingTaskRequest`, not to BGProcessingTask. No published value exists for iPhone 17 Pro on iOS 27.0.1.

### Cited Findings
- iOS 27.1 SDK `BGTaskRequest.h`, BGProcessingTaskRequest: "Schedule a processing task request to ask that the system launch your app when conditions are favorable for battery life to handle deferrable, longer-running processing … **The system will attempt to fulfill this request to the best of its ability within the next two days as long as the user has used your app within the past week.**" — local `iPhoneOS27.1.sdk/System/Library/Frameworks/BackgroundTasks.framework/Headers/BGTaskRequest.h`
- Same header, `requiresExternalPower`: "the system will launch your app to fulfill this request only while the device is connected to external power. **Setting this to `YES` will also disable the CPU Monitor feature.** … even if this value is `NO`, the system will not necessarily schedule this task while the device is on battery power". — local SDK header
- Same header: `BGHealthResearchTaskRequest.protectionTypeOfRequiredData` defaults to `NSFileProtectionCompleteUntilFirstUserAuthentication`. That implies processing tasks are expected to run while the device is locked. — local SDK header
- `BGTaskScheduler.h`: `supportedResources` is "A bitfield of the resources the device supports for `BGContinuedProcessingTaskRequest` instances". Apple docs: "Additional system resources that a continuous background task can request". — local SDK `BGTaskScheduler.h`; [Apple: supportedResources](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler/supportedresources)
- `.gpu`: requires `com.apple.developer.background-tasks.continued-processing.gpu` ("Background GPU Access" capability). "Background GPU execution is not supported on all devices. Additionally, if a device is experiencing heavy GPU contention backgrounded workloads are not guaranteed runtime." — local SDK `BGTaskRequest.h`; [Apple: Resources.gpu](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu)
- Developers reported `supportedResources.contains(.gpu)` false on iPhone 15 Pro and 16 Pro (iOS 26). DTS (Nov 2025) said it is not available on iPhone. — as recorded in `on_device_llm_summarization.md` and `ios_ble_background_streaming.md`
- The "Performing long-running tasks" doc still describes only GPU "(on supported devices)" for continued tasks and has not been updated with the ANE entitlement. — [Apple: Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)
- Apple: schedule heavy work "for periods of low activity, such as overnight when the device charges … such as training machine learning models or performing database maintenance … using BGProcessingTask, and the system decides the best time". — [Apple: Choosing Background Strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- Quinn (DTS): processing tasks are not guaranteed any schedule; "I typically see these run overnight." Clearing requiresExternalPower only means the task *can* run on battery. — [Forums 685525](https://developer.apple.com/forums/thread/685525), [Forums 127500](https://developer.apple.com/forums/thread/127500) (via search summary and prior note)
- The CPU monitor has killed BGProcessingTasks without external power ("exceeding limit of 80% cpu over 60 seconds"). — [Forums 690666](https://developer.apple.com/forums/thread/690666)
- Background ANE inside any task requires the entitlement ("regardless of whether it's running a continued background task"). — [Apple: Background Inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference)
- Runtime length: Apple publishes none. Third-party guides say "several minutes", and that the task is expired when the user starts using the device. No measured figures were found. — search summaries of third-party guides (e.g. [swiftcrafted.dev](https://swiftcrafted.dev/article/swiftui-background-tasks-ios-26-bgapprefreshtask-bgprocessingtask-bgcontinuedprocessingtask)); treat as low confidence

### Inferences
- For a user who charges every night and opens FreeBee daily, expect roughly one on-charger BGProcessingTask window per night, plausibly while the phone is locked and idle. It can run minutes to longer but can be expired at any time (for example when the user picks up the phone). This is the best-supported reading. Apple guarantees only "best effort within two days", so the pipeline must checkpoint per segment and resume.
- Engines inside that task:
  - CPU work: available with the CPU monitor off, so `.cpuOnly` Parakeet, pyannote and Silero are viable here at whatever CPU RTF they achieve.
  - ANE: only with the Background Inference entitlement.
  - SpeechTranscriber and Foundation Models: probably available, since they are system-managed. On power, the iOS 26-era FM guidance says throttling is "not expected", but neither is documented for a locked device.
- The question "does supportedResources contain .gpu for BGProcessingTask" is malformed. GPU for background work exists only through `BGContinuedProcessingTask`. That task must be started by a user action in the foreground, so it cannot be the nightly job. Still read `BGTaskScheduler.supportedResources` at runtime on the iPhone 17 Pro to decide whether a "Process now" continued task can request `.gpu`.
- Request the Background Inference entitlement, then measure it inside BGProcessingTask. If it works there, the nightly Parakeet/pyannote passes can use the ANE. If not, plan nightly CPU-only passes, or use SpeechTranscriber for ASR.

### Gaps
- No public measurements of BGProcessingTask grant frequency or run length on iOS 26/27 for always-on-charger users. Log `Date()` at start and at expiration over a week (Console subsystem `com.apple.backgroundtaskscheduler`).
- No source on whether Foundation Models or SpeechTranscriber run inside a BGProcessingTask while locked.
- `supportedResources` on iPhone 17 Pro / iOS 27.0.1 is unreported. It must be read on the device.

## 5. Can app files and the SwiftData/SQLite store be written while locked under the default protection class?

### Takeaway
Yes, after the first unlock since boot. iOS's default file protection is `completeUntilFirstUserAuthentication`, and Core Data (which SwiftData sits on) defaults stores to the same class. FreeBee sets no data-protection entitlement and its `ModelConfiguration` sets no protection, so both capture files and the SwiftData store stay writable while locked. Before the first unlock after a reboot, nothing is accessible, but BLE state restoration doesn't relaunch the app until then anyway.

### Cited Findings
- "If you do not specify a protection level when creating a file, iOS applies the default protection level automatically … **Complete until first user authentication. (Default)** The file is inaccessible until the first time the user unlocks the device. After the first unlocking of the device, the file remains accessible until the device shuts down or reboots." Apple also says to use "complete unless open" or a non-`complete` level for files accessed in the background. — [Apple: Encrypting Your App's Files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)
- `.completeUntilFirstUserAuthentication`: "After the user unlocks the device for the first time, your app can access the file and continue to access it even if the user subsequently locks the device." — [Apple](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication). `.complete`: "cannot be read from or written to while the device is locked or booting." — [Apple](https://developer.apple.com/documentation/foundation/fileprotectiontype/complete)
- `NSPersistentStoreFileProtectionKey`: "The default value is `completeUntilFirstUserAuthentication` for all applications built on or after iOS v5.0." — [Apple: NSPersistentStoreFileProtectionKey](https://developer.apple.com/documentation/coredata/nspersistentstorefileprotectionkey)
- SwiftData's `ModelConfiguration` in the iOS 27.1 SDK has no file-protection parameter. Its options are name, schema, `isStoredInMemoryOnly`, `allowsSave`, `groupContainer` (default `.automatic`), url and cloudKitDatabase. — local `SwiftData.framework/.../arm64e-apple-ios.swiftinterface`
- FreeBee creates `ModelConfiguration(isStoredInMemoryOnly: preview)` with defaults (`FreeBee/Model/BeeStore.swift:77`), and its entitlements have no `com.apple.developer.default-data-protection`. — local source
- After a reboot, Bluetooth-restored apps "will not be relaunched until the device is unlocked for the first time". — [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) (via `ios_ble_background_streaming.md`)

### Inferences
- As built today, capture segments and the SwiftData store (including SQLite `-wal`/`-shm` files, created under the same default class) are writable from BLE-woken background code and from overnight BGProcessingTasks while the phone is locked. Two things would break this:
  - adding the Data Protection capability set to "Complete";
  - explicitly writing with `.completeFileProtection`.

  Avoid both for capture and processing data.
- The Keychain is a related lock-state risk. The 108-byte SKV1 session token must be readable while locked, or session open after a background reconnect will fail. If it is stored in the Keychain, use an after-first-unlock accessibility class. This is inference; Keychain accessibility was not researched in this pass.
- With `groupContainer: .automatic` and an app-group entitlement, the store probably lives in the shared group container, which also uses the default class. Not verified.

### Gaps
- No Apple doc states SwiftData's default protection explicitly. It is inferred from Core Data's documented default.
- Unverified: whether a first launch before first unlock (impossible for BLE restoration, possible for BGTasks) fails gracefully when opening the store. Handle `ModelContainer` init errors.

## 6. Fact-check of doubtful claims in earlier notes

### Takeaway
The biggest correction: iOS 27 GA formally gates background ANE behind a new entitlement. FluidAudio's "ANE so background works" is false for FreeBee as currently configured. The other claims are confirmed as doubtful or remain unverifiable; this pass found no new primary evidence on them, apart from an iOS 27 known issue affecting SpotlightSearchTool.

### Cited Findings
- **Claim: "Parakeet Ultra runs on the ANE (so iOS background transcription works)", "Background-friendly: Yes"** → **Corrected.** iOS 27 "restricts background access to the Neural Engine". Background ANE "requires the new entitlement" for "any Neural Engine access while your app is in the background", via Core ML or Core AI. FreeBee doesn't have it. The matrix cell should read "Only with the iOS 27 Background Inference entitlement; untested on 27.0.1; otherwise `.cpuOnly` (RTF unmeasured) or defer." — [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes); [Background Inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference); [Forums 832048](https://developer.apple.com/forums/thread/832048)
- **Claim: iPhone throughput and energy figures (Parakeet 40–75x, pyannote 80–160x, 3–5 W, 10–30 min ANE/day, 3–8% battery)** → **Unverifiable, and partly invalidated.**
  - No iPhone measurements were found.
  - The figures assume background ANE access, which iOS 27 now gates.
  - If work moves to `.cpuOnly`, the energy and time estimates don't apply.
  - The "moondream post-train of v3" weight provenance and license were not checked in this pass and remain open.

  — sources as above; `on_device_speech_audio_ml.md` lines ~105, 319
- **Claim: pyannote community-1 port "10.6% DER" on AMI-SDM** → **Doubt confirmed by the note's own sources.** FluidAudio's benchmarks page says the protocol differs from pyannote's (19.9%), and the egocentric (Ego4D) figure for community-1 is 46.8%. No new evidence in this pass. — [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md) (via `on_device_speech_audio_ml.md` lines 202–229)
- **Claim: "Default to sleep with hardware VAD (state 2) so the Bee only streams on speech"** → **Unverifiable / speculative.** `bee_device_audio.md` says no source has published whether states 2/4 wake on speech and stream, and proposes an experiment. — `bee_device_audio.md` lines 43, 60, 66
- **Claim: "physical button presses do not act on the device; A001/A002 only relayed"** → **Corrected.** jkmills confirmed on hardware that "a single physical button press toggles the device's own recording LED on/off, and audio streaming genuinely starts/stops with it". With a session open it pushes `A003`. Treat `A003` as the source of truth. — [jkmills PROTOCOL.md](https://github.com/jkmills/bee-wearable-ble/blob/main/PROTOCOL.md) (via `bee_device_audio.md` line 50)
- **Claim: Bee battery "1.5–2 days vs 7" / "about 2 days" as fact** → **Unverifiable.** The sources are a competitor (UMEVO) and an App Store review ("three long days of work"). No measured continuous-streaming figure exists. — `bee_device_audio.md` lines 21–37
- **Claim: EmbeddingGemma + sqlite-vec primary; Spotlight semantic index / SpotlightSearchTool as the Apple-native path** → **Unverifiable as stated, with one new caveat.**
  - Still no Core ML/MLX EmbeddingGemma build, and no iPhone latency.
  - The iOS 27 release notes add a known issue: "Creating a SpotlightSearchTool without a configuration and using it with a LanguageModelSession backed by the on-device system language model fails with an error reporting that the number of tokens provided exceeds the maximum allowed … Workaround: Configure the tool with a focused guide … `.focused(.communications)` … (183770678)".
  - No source in this pass confirms that the Spotlight semantic index is fully on-device.

  — [iOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes); `on_device_llm_summarization.md` line 235
- **Claim (LLM note): "Only Apple's Foundation Models is reliably usable in the background"** → **Corrected to "best-effort".** Apple (June 2026): background requests "might be throttled or canceled". The iOS 27 `rateLimited` doc no longer limits throttling to the background. — [Forums 833642](https://developer.apple.com/forums/thread/833642); [LanguageModelError.rateLimited](https://developer.apple.com/documentation/foundationmodels/languagemodelerror/ratelimited(_:))

### Inferences
- Where each stage runs, on the evidence so far:
  - **Near real time in the BLE background:** decrypt, ADTS, AAC decode, Silero on `.cpuOnly`, and append to disk. Optionally SpeechTranscriber (likely out of process, unproven) and short FM extraction (best-effort).
  - **Foreground catch-up:** Parakeet and pyannote on the ANE.
  - **Charger overnight (BGProcessingTask, CPU monitor off):** heavy passes. They use the ANE only if the Background Inference entitlement is granted and works; otherwise CPU or SpeechTranscriber.
- ASR engine choice: SpeechTranscriber is the safer default for background or locked work on iOS 27. Parakeet stays the accuracy upgrade for foreground and overnight passes, depending on the entitlement.

### Gaps
- Every iOS 27.0.1 runtime behaviour above (ANE error vs fallback, CPU RTF, SpeechTranscriber and FM while locked, BGProcessingTask cadence, `supportedResources`) lacks published device data. A one-day on-device probe on the user's iPhone 17 Pro would settle most of it.
- The Parakeet Ultra derivative-weights licence and provenance were not researched in this pass.
