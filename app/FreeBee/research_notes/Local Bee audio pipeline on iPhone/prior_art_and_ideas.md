# Prior art in always-on AI wearables and local-first transcription, and ideas for FreeBee (local-only Bee + iPhone)

Scope note: research done 2026-10-20 with web search and fetch. About 25 tool calls, so a few products (Humane, Rabbit, MacWhisper, Aiko, Superwhisper, Owl) got only shallow coverage or none; they are listed under Gaps. Every item under "Cited Findings" has a source. Items under "Inferences" are our own design reasoning for FreeBee, not facts from the sources.

## 1. How the official Bee app presented data, and what reviewers thought

### Takeaway
The official Bee app had five parts: Daily Memories (a day summary), a conversation list (each with "vibe", takeaways and speakers), suggested to-dos, "Facts" about the user, and a chat called "Buzz". Reviewers liked the to-do capture and the daily recaps. Their main complaints were too much output to review, false positives from TV and podcast audio, nonsense "facts", short battery life, and a mute button people forgot to use.

### Cited Findings
- Daily Memories: tapping one shows a summary of the day with key events and topics. Each conversation opens to its "vibe", main takeaways and who was speaking, with the full transcript underneath. — [mikecann.blog, 13 Mar 2025](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- To-dos: the app periodically suggested to-dos, and each could be added or dismissed. The reviewer reviewed about 15 per day and said the automatic to-dos "reliably caught things he said". — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- Facts: short snippets about the user that Bee thought it had learned. They often contained nonsense (for example "apparently I want a puppy?"), and the reviewer had to verify 25+ per day. — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- "Buzz" was the chat for asking about conversations and history. The reviewer found its answers about relationships and self-perception "surprisingly spot-on". — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- Failure modes reported:
  - True-crime podcasts and other media were treated as real conversation.
  - Effective mic range was about 2–3 m.
  - Users forgot to press mute before media played.
  - Notification controls were so coarse the reviewer turned off all notifications, which also hid useful to-do reminders.
  - Battery lasted about 2 days against a 7-day claim, with noticeable phone battery drain.
  — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- Bee claimed it transcribed on the phone and deleted recordings right away. The reviewer was uneasy that the app asked for calendar, contacts, email and notes access at onboarding. — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant)
- Bee suggested dozens of to-dos a day, many pulled from TV or podcast audio, and each had to be approved one by one. — [Forbes Vetted, Best AI Wearables 2026](https://www.forbes.com/sites/forbes-personal-shopper/article/best-ai-wearables/)
- A Vice reviewer reported that misidentified speakers led to invented details about their life (secondhand). — [Vantaige summary](https://vantaige.io/ai-tool/bee-ai)
- Post-Amazon features (TechCrunch, 7 Jan 2026):
  - Email and calendar integration: Bee drafts emails and creates events when told to.
  - Pressing the device button records a voice note that shows up in the app.
  - Daily insights and mood patterns, only for users who wear the device continuously.
  — [TechCrunch](https://techcrunch.com/?p=3080273)
- 2026 review (14 Apr 2026, updated Aug 2026):
  - Liked: daily recaps of commitments and follow-ups were "surprisingly useful".
  - Disliked: summaries were hit-or-miss, and always-on recording produced "a lot of data for inconsistent returns".
  - Pricing: free since the Amazon acquisition (the earlier $19/mo was dropped). Hardware is $49.99, US-only.
  - Battery: about 1.5–2 days of active listening.
  - Privacy skepticism because of Amazon ownership.
  — [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/)
- Bee policy says audio isn't stored or used for training, and transcripts and insights are kept in the cloud. — [aiuse.blog](https://aiuse.blog/what-does-bee-ai-wearable-do/); [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/)
- In the official firmware and app, physical button presses do not act on the device. The app only relays them to Bee's backend, so they trigger no mute or other device action. — [jkmills/bee-wearable-ble README](https://github.com/jkmills/bee-wearable-ble)

### Inferences
- Keep the information architecture that reviewers valued: day, then conversations, then transcript, plus a to-do inbox and a chat. Redesign the parts that failed: volume, precision, media false positives, and notification control.
- To-dos need high precision and low volume:
  - Show them in a single "Review" inbox that can be cleared in one batch (swipe to accept or dismiss), not as individual notifications.
  - Put a cap on suggestions per day.
  - Only extract to-dos from segments where the wearer is the speaker or is directly addressed. This needs speaker enrollment of the wearer (see section 4).
- Make "Facts/Memories" opt-in or rare:
  - Require repeated evidence across at least two conversations before proposing a fact.
  - Always link each fact to its source quote and timestamp so it can be verified in one tap.
- Since the official app gave buttons no on-device behavior, FreeBee is free to define A001 and A002. Any action must be carried out by the phone, which means the Bee has to be connected.
- Granular notification settings per category are a cheap fix for a problem reviewers named explicitly.
- "Ask Bee/Buzz" can run fully on-device: on-device Foundation Models plus local retrieval over transcripts. Reviewers' praise for Buzz shows chat over your own history is a valued feature (see section 3).

### Gaps
- Exact Bee app screens for "Ask Bee", templates or "Actions" in the 2026 Amazon-era app were not found. No Verge, Wired or MKBHD review of Bee was retrieved in this pass.
- Whether the official app discarded A001/A002 or mapped them to features (for example the voice notes TechCrunch describes) on Pioneer hardware, as opposed to newer hardware, is unconfirmed.

## 2. Omi and other wearables (Limitless, Plaud NotePin, Friend, Rewind, Humane, Rabbit): architecture and lessons

### Takeaway
Omi is the best open reference (MIT license, nRF/Zephyr firmware, Flutter app, FastAPI backend). It streams 16 kHz Opus over BLE using a small packet header, segments conversations with a user-adjustable silence timeout, then produces a transcript, summary, action items and memories. Its consumer app transcribes in the cloud (Deepgram), so its STT path is not something we can copy, though its UX and protocol patterns are. Limitless (Meta) and Rewind are effectively ended products. Plaud succeeds by recording only on intent and offering summary templates. Friend shows what goes wrong with an always-on device that has no mute.

### Cited Findings
- Omi BLE protocol:
  - Audio service `19B10000-E8F2-537E-4F6C-D104768A1214`, with audio data at `19B10001-…` and codec type at `19B10002-…`.
  - Codec IDs: 0 = PCM16 16 kHz, 1 = PCM16 8 kHz, 10/11 = μ-law, 20 = Opus 16 kHz. Opus is the default from firmware 1.0.3.
  - Each notification has a 3-byte header: a 16-bit little-endian packet counter that wraps at 65535, plus a 1-byte index. Packets larger than MTU−3 are split across notifications.
  - Battery uses the standard 0x180F service; notifications need firmware v1.5+.
  — [Omi App-Device Protocol docs](https://docs.omi.me/doc/developer/Protocol)
- Omi firmware encodes mono Opus at 16 kHz in 160- or 320-sample frames. Codec 21 is "Opus FS320" (20 ms frames); the RN SDK had mis-mapped it to PCM8 until a patch. A PR notes the repo cannot confirm that every notification is exactly one Opus packet. — [omi PR #19546](https://github.com/BasedHardware/omi/pull/19546); [omi issue #13026](https://github.com/BasedHardware/omi/issues/13026)
- Omi's backend transcription endpoint takes codec options opus, opus_fs320, aac and lc3. Its docs give pcm8 as the default, which conflicts with the protocol doc's Opus default. — [Omi Real-time Transcription docs](https://docs.omi.me/doc/developer/backend/transcription)
- The Omi Python SDK decodes Opus to PCM and sends it to Deepgram. The RN SDK also uses Deepgram. — [Omi Python SDK docs](https://docs.omi.me/doc/developer/sdk/python); [Omi React Native SDK](https://docs.omi.me/doc/developer/sdk/ReactNative)
- Omi architecture:
  - Flutter mobile app; native Swift/SwiftUI macOS app.
  - Python FastAPI backend on Firebase/Firestore and Redis, with GPU-side VAD and diarizer.
  - Deepgram is the only STT named.
  - nRF/Zephyr firmware.
  - App store and plugins (GitHub, Slack, an MCP server).
  - MIT license; self-hosting supported.
  — [BasedHardware/omi README](https://github.com/BasedHardware/omi)
- A community Swift SDK for Omi devices advertises "local Whisper-based transcription - no cloud API required". — [Friend/Omi Swift SDK mirror](https://gitcode.com/GitHub_Trending/fr/Friend/tree/main/sdks/swift/)
- Omi conversation pipeline:
  - Omi waits for a silence period, the "conversation timeout" (adjustable under Settings → Profile), then finalizes a Conversation and generates the transcript, summary and action items.
  - Processing needs internet.
  - Tasks can go to Google Tasks or Todoist.
  - A recording indicator on the device shows status.
  — [Omi help: Advanced settings](https://help.omi.me/en/articles/13153774-advanced-settings-settings-screen); [Omi help: Recording, transcription, apps and tasks](https://help.omi.me/en/articles/13154896-recording-transcription-apps-and-tasks)
- Omi changelog:
  - Action items sync two-way with Apple Reminders: create, complete or delete in either app and the other updates.
  - Offline recording on the device without the phone, synced later.
  - From firmware 3.0.17, offline recordings sync in the background while the device is in normal use.
  - Search covers summaries, tasks and memories.
  — [Omi changelog](https://feedback.omi.me/changelog)
- Offline sync reliability problems are reported: a 343 MB Opus SD-card download stalled ("SD card read stalled"), and server jobs stayed queued at 0%. The report is recent and unconfirmed by maintainers. — [omi issue #21279](https://github.com/BasedHardware/omi/issues/21279)
- Limitless:
  - Meta acquired it in Dec 2025. Pendant sales to new customers stopped, and existing owners got support for "at least a year" and a free move to the Unlimited plan.
  - Rewind desktop capture and Limitless desktop/web recording were disabled on 19 Dec 2025.
  - Users in the EU, UK, Brazil, Israel, South Korea, Turkey and China lost service, with export and delete tools offered.
  — [TechInformed](https://techinformed.com/meta-acquires-limitless-pendant-users-moved-to-free-unlimited-plan/); [9to5Mac](https://9to5mac.com/2025/12/05/rewind-limitless-meta-acquisition/)
- One Trustpilot user says Limitless service was discontinued "from one day to the next" (anecdotal). — [Trustpilot](https://no.trustpilot.com/review/limitless.ai)
- Limitless "Consent Mode" (2024 launch claim): voice identification so the pendant only captures voices of people who have verbally consented. A visible LED shows recording. — [Business Insider (2024)](https://WWW.BUSINESSINSIDER.IN/limitless-ai-pendant-clips-clothes-hears-records-everything-2024-4); [TechCrunch 2024](https://techcrunch.com/2024/04/17/a16z-backed-rewind-pivots-to-build-ai-powered-pendant-to-record-your-conversations/)
- Limitless's advertised 100-hour battery dropped to about 6–14 h with continuous recording. A 2026 reviewer singled out Consent Mode as a privacy feature Bee lacks. — [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/)
- Plaud NotePin / NotePin S:
  - Records only when intentionally started.
  - 10,000+ summary templates by conversation type, plus custom templates.
  - Speaker labels. Plaud's own blog says labels and custom templates are Pro-gated; a review says Starter includes them, so the sources conflict.
  - $179 hardware, 300 min/mo Starter, Pro $99.99/yr for 1,200 min.
  - A 2026 reviewer ranked it first, citing intentional recording and independence from big tech.
  — [Plaud blog: speaker labels and templates](https://uk.plaud.ai/blogs/news/updates-label-the-speakers-and-create-your-own-templates); [Mighty Gadget NotePin S review](https://mightygadget.com/plaud-notepin-s-review-vs-plaud-note-pro/); [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/); [Tom's Guide](https://tomsguide.com/ai/plaud-notepin-review)
- Friend pendant:
  - Wired's review, "I Hate My Friend", found "nothing at all to recommend it".
  - The mic cannot be muted and listens continuously. A Wired journalist was taken for wearing an eavesdropping device.
  - Relaunched with a speaker at $249, plus an optional $9.99/mo memory subscription (The Verge, via secondary).
  - Users report about 4 h battery against a 15 h claim (forum, anecdotal).
  — [Boing Boing on Wired](https://boingboing.net/2025/09/08/ai-powered-eavesdropping-gadgets-reviewed.html); [Let's Data Science](https://letsdatascience.com/news/friend-relaunches-ai-pendant-with-speaker-for-249-85de4fb2); [heyupnow forum](https://community.heyupnow.com/d/12161-friend--powered-companion-necklace-shipped-but-screw-up)
- jkmills/bee-wearable-ble, the prior Bee reverse-engineering work:
  - Local transcription with faster-whisper and diarization with pyannote 3.1.
  - Per-speaker embeddings matched by cosine similarity to a local `speaker_profiles.json`, prompting to name unknown speakers, with profiles updated by running average.
  - A PANNs (AudioSet) tagger to flag TV, radio or music segments, described as a "coarse heuristic".
  - Both hw-vad and sw-vad sleep modes confirmed on hardware.
  — [jkmills/bee-wearable-ble](https://github.com/jkmills/bee-wearable-ble)

### Inferences
- Packet framing:
  - Omi's 16-bit wrapping counter plus split index is the same design idea as the Bee's uint32 BE sequence. The Bee's 32-bit counter is better because it never wraps within a session, so we can do exact gap accounting.
  - Omi's history (codec ID mis-mapping, unclear packet-to-frame boundaries) argues for strict per-frame validation: check the ADTS syncword and frame length after decryption, and count bad frames separately from lost packets.
- Segmentation: copy Omi's "conversation timeout" as a user setting, and add a manual override on A002 (hold = "end/split conversation now", or "start a note").
- Reminders: copy Omi's two-way Apple Reminders sync through EventKit, using a dedicated "FreeBee" list, but only after the user accepts a suggestion (see section 1).
- Consent and privacy: Limitless Consent Mode can be done locally with on-device speaker embeddings. Keep the wearer's and enrolled people's speech, and redact or drop unenrolled voices from transcripts. This gives a real differentiator for a mode where bystander speech is not transcribed.
- Mute: Friend's no-mute design was heavily criticized. Mute must be one action away everywhere: device button, Live Activity, Control Center control, Watch and Siri.
- Business-model risk: Limitless, Rewind and Bee were all bought, then changed or shut down. That validates a local-only design with an open export format. Make everything exportable (Markdown/JSON plus audio) so the user is never stranded.
- Storage: Omi's offline-storage problems show that on-device storage plus bulk BLE sync is fragile. If the Bee has no flash buffer, our out-of-range resilience has to come from fast reconnect plus phone-side buffering (see section 5).

### Gaps
- Not verified in this pass: Humane AI Pin's end of life (widely reported as HP acquiring Humane and the pin shutting down in Feb 2025) and Rabbit R1's 2025–2026 status and lessons.
- Not found: Owl and other open-source pendant projects; Omi's exact default conversation-timeout value; whether Omi's consumer app now offers any on-device STT; Omi's button gesture mappings.
- Whether Limitless Consent Mode ever shipped is unclear. A Limitless feedback board still lists it as an idea ([Limitless feedback](https://feedback.limitless.ai/b/kvj1nlve/feature-ideas/android-app)).

## 3. Local-first and private transcription on Apple platforms: UX patterns (Apple Notes/Voice Memos/Phone, Hyprnote, FluidAudio-based apps)

### Takeaway
Apple's own pattern is: record, put the recording in Notes (Call Recordings folder) with a transcript, offer a "Summary" button, and warn users to check important details against the audio. Calls get a mandatory audible notice to all participants. In 2026 the on-device third-party stack has converged on Parakeet (CoreML/ANE) and Whisper for ASR, Silero VAD, and pyannote or LS-EEND/Sortformer diarization, mostly through FluidAudio (Apache-2.0). iOS 27 adds model-agnostic Foundation Models, a "Core AI" framework for running custom models on-device, and App Intents entity schemas that feed the Spotlight semantic index.

### Cited Findings
- Apple Phone call recording:
  - Recordings land in Notes in a "Call Recordings" folder.
  - Transcripts are available only in select regions and languages and may take time to appear.
  - In Notes, "Summary" produces an Apple Intelligence summary that can be copied or shared.
  - Apple advises checking important details against the audio.
  - Call recording is not offered in the EU and some other regions.
  — [Apple Support: Record and transcribe a call](https://support.apple.com/guide/iphone/record-and-transcribe-a-call-iph57c6590e9/ios); [Apple Support: Summarize an audio recording (Notes)](https://support.apple.com/guide/iphone/summarize-an-audio-recording-iph59143007d/ios); [Apple Support: Apple Intelligence in Phone](https://support.apple.com/en-gb/guide/iphone/iph2571a9780/ios)
- On iOS 27, Apple Intelligence requires an iPhone 15 Pro / 15 Pro Max or an iPhone 16 or newer. — [Apple Support (search snippet of Apple Intelligence in Phone/Notes pages)](https://support.apple.com/en-gb/guide/iphone/iph2571a9780/ios)
- iPhone call recording plays an audio notice to all participants when recording starts and again when it stops, and there is no setting to disable it. — [Plaud blog (competitor source)](https://www.plaud.ai/blogs/articles/iphone-call-recording-without-announcement); [Yahoo Tech](https://tech.yahoo.com/ai/apple-intelligence/articles/record-phone-call-iphone-where-001800753.html)
- Voice Memos got on-device transcription in iOS 18. iOS 26 added AI summaries and the new SpeechAnalyzer engine (third-party guides, not Apple docs). — [Sonix guide](https://sonix.ai/ai/can-apple-intelligence-transcribe-audio/); [ConvertAudioToText guide](https://convertaudiototext.com/blog/recording-and-transcribing-on-iphone)
- WWDC26 / iOS 27 (Apple's iOS guide):
  - Foundation Models can now "work with any language model, including Apple Foundation Models, cloud models like Claude and Gemini, or any other provider that conforms to the Language Model protocol".
  - Multimodal prompts, with Vision OCR and barcode tools callable by the model on-device.
  - "Dynamic Profiles" to swap models, tools and instructions within a session.
  - A new Evaluations framework.
  - Free Private Cloud Compute model access for Small Business Program apps.
  — [Apple WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)
- New "Core AI": "A modern, memory-safe Swift API lets you load, specialize, and run AI models entirely on-device … with zero server dependencies and zero token costs". It offers ahead-of-time compilation, fine-grained inference memory control, zero-copy data paths and stateful execution. — [Apple WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/)
- App Intents in iOS 27:
  - "Entity schemas contribute your app's content to the Spotlight semantic index, so Siri can surface it with attribution back to your app".
  - "Intent schemas" let people act on that content with no predefined phrases.
  - A View Annotations API maps views to entities.
  - An App Intents Testing framework.
  - Widgets can be customized through App Intents.
  - There is a session titled "LLM search using Core Spotlight".
  — [Apple WWDC26 iOS guide](https://developer.apple.com/wwdc26/guides/ios/); [MacRumors, 9 Jun 2026](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)
- Third-party claims, unverified against Apple docs:
  - The iOS 27 on-device model has an 8,000-token context and is named "AFM 3 Core".
  - iOS 27 connects transcription modules to the language-model session.
  — [dracode](https://dracode.dev/blog/2026-06-15-08-foundation-models-ios27-free-ai/); [callstack](https://www.callstack.com/blog/on-device-ai-after-wwdc-2026-whats-new); [forasoft](https://www.forasoft.com/blog/article/speech-recognition-with-neural-networks-on-ios-1621)
- FluidAudio (Swift SDK, Apache-2.0 code, models mostly MIT/Apache; Sortformer under NVIDIA Open Model License):
  - ASR:
    - Parakeet TDT v3 0.6b covers 25 European languages plus Japanese.
    - Parakeet EOU 120m does streaming ASR with end-of-utterance detection (English).
    - Other variants: Parakeet TDT v2 (English).
  - VAD: Silero.
  - Diarization:
    - Offline: pyannote Community-1 (powerset segmentation + WeSpeaker + VBx).
    - Streaming: LS-EEND (recommended default, up to 10 speakers) and Sortformer (4-speaker limit).
  - Speaker embeddings are exposed.
  - Performance: ASR runs about 190× real-time on an M4 Pro (1 h in about 19 s). No iPhone ASR or diarization benchmark was on the README.
  - Apps using it include VoiceInk, Spokenly, Slipbox, Hex and Hedy.
  — [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- FluidAudio benchmarks (secondary): pyannote CoreML at 15% DER offline and Sortformer at 31.7% DER streaming (M4 Pro). — [FluidAudio docs/search listing](https://docs.fluidinference.com)
- Hyprnote:
  - Open-source, local-first meeting notetaker (YC S25 launch on HN).
  - Runs offline with Whisper or "HyprLLM". Summaries can use local LLMs (Ollama, LM Studio) or user-supplied keys.
  - Captures system audio, incoming and outgoing, without bots.
  - It appears to have been renamed or reorganized (a Product Hunt listing as "Anarlog"; a YC company "Char" lists a former Hyprnote founder). The relationship is unconfirmed.
  — [Brian Lovin HN mirror](https://brianlovin.com/hn/44725306); [Product Hunt (Anarlog)](https://www.producthunt.com/p/hyprnote/anarlog); [YC: Char](https://www.ycombinator.com/companies/char); [hyprnote GitHub fork](https://github.com/PythonTilk/hyprnote)
- OpenWhispr for iOS (open source) uses whisper.cpp by default with Parakeet as a second engine, and does speaker labeling locally. — [Product Hunt OpenWhispr iOS](https://www.producthunt.com/p/openwispr-open-source-ai-speech-to-text/openwhispr-for-ios); [OpenWhispr docs](https://docs.openwhispr.com/guides/local-models.md)

### Inferences
- Transcript UX to adopt (Apple and Plaud patterns):
  - Show transcript, Summary, and a "verify against audio" affordance: tap a sentence to play from that timestamp.
  - Speaker labels the user can rename once, with the rename applied to every past conversation through embeddings.
  - Summary templates per conversation type (meeting, 1:1, lecture, errand, journal), chosen automatically and switchable by the user.
- ASR on iPhone 17 Pro:
  - Leading candidates are SpeechAnalyzer (system, zero model download; iOS 26+) or Parakeet via FluidAudio on the ANE.
  - Keep mlx-whisper / Whisper large-v3-turbo for the Mac offload path. Our existing beekit `transcribe.py` already uses mlx-whisper.
  - Benchmark both on the real Bee audio, which is 16 kHz AAC at 32 kbps from 2–3 m: compare WER, latency and battery.
- Diarization: use FluidAudio's LS-EEND for live labels and the pyannote Community-1 offline pass when charging, then cluster against enrolled-speaker embeddings, mirroring jkmills' `speakers.py`.
- Summaries: use the on-device Foundation Models default model only. iOS 27 lets the framework talk to cloud providers, so FreeBee should hard-pin the on-device model and expose a visible "on-device only" guarantee in Settings. Do not use PCC, which is cloud even if private.
- Siri and Spotlight: expose Conversation, Person, Todo and DaySummary as App Entities with iOS 27 entity schemas so Spotlight's semantic index and Siri can answer "what did Alex say about the budget?" locally. Verify that the semantic index is on-device before relying on it.
- Use the "LLM search using Core Spotlight" session approach, or a local embedding index, for "Ask Bee".
- Privacy UX patterns:
  - A persistent recording indicator. The Live Activity / Dynamic Island acts as the "LED".
  - A clear "audio deleted after transcription" setting.
  - A consent-reminder pattern borrowed from Apple's call notice: optionally play a chime from the phone, or show a "Recording" card when a new speaker is detected.

### Gaps
- MacWhisper, Aiko, Superwhisper and Voice Memos-specific UI (speaker labels, search) were not researched in this pass.
- Exact iOS 27 changes to SpeechAnalyzer (new languages, diarization, custom vocabulary) were not found in Apple primary sources. The iOS 27 on-device context window was not confirmed by Apple.
- Whether the iOS 27 Spotlight semantic index runs fully on-device is not confirmed.
- On-iPhone RTF and battery numbers for Parakeet and LS-EEND were not published on the README.

## 4. Segmentation heuristics, memory formats, daily digests and privacy features

### Takeaway
Shipping products segment conversations mainly by silence timeout (Omi) or explicit user intent (Plaud, Bee voice notes). The best newer tools add end-of-utterance models and streaming diarization. Memory and "fact" extraction is the most-criticized output category (Bee: 25+ dubious facts a day), while daily recaps of commitments are the most-praised. The privacy features users and reviewers value most are a mute that really works, a visible recording indicator, no stored audio, consent gating, and full export.

### Cited Findings
- Omi finalizes a "Conversation" after a configurable silence "conversation timeout", then generates summary and action items. — [Omi help](https://help.omi.me/en/articles/13153774-advanced-settings-settings-screen)
- Parakeet EOU provides streaming end-of-utterance detection, and LS-EEND/Sortformer provide streaming speaker-change information. — [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- Bee's "Facts" were frequently nonsense and required 25+ verifications a day. To-dos were helpful but numerous (about 15/day, or "dozens" per Forbes). — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant); [Forbes](https://www.forbes.com/sites/forbes-personal-shopper/article/best-ai-wearables/)
- Daily recaps of commitments and follow-ups were "surprisingly useful", while generic AI summaries were hit-or-miss. — [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/)
- Bee offered daily mood insights, but only for continuous wearers. — [TechCrunch](https://techcrunch.com/?p=3080273)
- Privacy features in prior art:
  - Bee claimed audio is deleted after processing.
  - Limitless had Consent Mode plus a recording LED.
  - Omi has an on-device recording indicator.
  - Apple plays a mandatory audible call-recording notice.
  - Limitless offered export and delete tools before shutdown.
  - Friend was criticized for having no mute.
  — [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant); [Business Insider](https://WWW.BUSINESSINSIDER.IN/limitless-ai-pendant-clips-clothes-hears-records-everything-2024-4); [Omi help](https://help.omi.me/en/articles/13154896-recording-transcription-apps-and-tasks); [Plaud blog](https://www.plaud.ai/blogs/articles/iphone-call-recording-without-announcement); [TechInformed](https://techinformed.com/meta-acquires-limitless-pendant-users-moved-to-free-unlimited-plan/); [Boing Boing](https://boingboing.net/2025/09/08/ai-powered-eavesdropping-gadgets-reviewed.html)
- Some US states require all-party consent for recording. Consent Mode alone does not settle legal obligations. — [Business Insider](https://WWW.BUSINESSINSIDER.IN/limitless-ai-pendant-clips-clothes-hears-records-everything-2024-4); [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/)
- A PANNs AudioSet tagger can flag TV, radio and music segments, but it is a coarse heuristic. — [jkmills/bee-wearable-ble](https://github.com/jkmills/bee-wearable-ble)

### Inferences
Segmentation recipe for FreeBee (our design, layered):
- (a) Hardware/software VAD gating on the Bee (states 2/4) for coarse speech presence.
- (b) Phone-side Silero VAD plus an EOU model for utterance boundaries.
- (c) Conversation boundary when silence exceeds T. Default about 2–3 min, user-adjustable like Omi.
- (d) Conversation boundary when the speaker set changes (new diarization cluster with no overlap with the previous one).
- (e) Conversation boundary on a significant-location change (CoreLocation visits) or the start or end of a Calendar event.
- (f) Manual split on A002 hold.
- (g) Media segments (TV, music, podcast per audio tagger, Apple SoundAnalysis, or "no enrolled speaker and continuous speech") are marked "media" and excluded from to-do and fact extraction by default. This targets the most common Bee and Forbes complaint.

Memory format, as structured on-device Foundation Models output (iOS 26+ guided generation; verify the API in iOS 27). Every item carries a provenance pointer (conversationID, start/end time, speakerID, quote), confidence, and status (suggested, accepted, rejected). Item types:
- `Todo{text, owner, due?, source}`
- `Commitment{by, to, what}`
- `Fact{subject, predicate, object, evidenceCount}`
- `Event{title, date?}`
- `Person{name, embeddingID}`

Rejected items feed negative examples into the prompt to reduce repeats.

Daily digest design:
- A "Commitments and follow-ups" section first (the most-praised content).
- Then "People you talked to", using speaker names and calendar attendees.
- Then a 3–5 bullet day summary.
- Then "Needs review" (to-dos and facts awaiting approval).
- Then stats: minutes captured, minutes muted, audio quality, battery.
- Deliver once in the evening as a local notification, plus a widget. No push for every item.

Privacy feature set:
- Quick mute everywhere: double-press A001, Live Activity button, Control Center control, Watch, "Hey Siri, mute Bee". This uses SetDeviceState C006 state 0.
- An always-visible state in the Live Activity / Dynamic Island.
- Auto-delete audio N hours after successful transcription, defaulting to off for raw audio. Keep only the transcript, with optional retention of starred clips.
- Data Protection "complete" file protection plus a Face ID app lock. Note that with complete protection, background writes while the phone is locked need "complete unless open" or a staged buffer.
- An opt-in "Consent mode" that transcribes only enrolled voices and redacts others.
- A geofenced or Focus-based "never record here" setting (bedroom, doctor) via Shortcuts automations calling a Mute intent.
- Local export (Markdown/JSON plus audio) and "delete everything".

### Gaps
- No primary source gave Omi's default silence timeout, or any product's speaker-change or location-based segmentation rules. Items (d) and (e) above are our own proposals.
- No published structured "memory" schema from Omi, Bee or Limitless was retrieved. Omi's REST API exposes memories, conversations and action items ([omi README](https://github.com/BasedHardware/omi)), but the field-level schema was not inspected.

## 5. Robustness: out-of-range buffering, catch-up while charging, quality metrics, battery, and Mac offload

### Takeaway
Prior art handles disconnection with on-device storage and later sync (Omi, offline recording; background sync from firmware 3.0.17). That path is reportedly fragile, with stalled SD-card sync and stuck jobs. For FreeBee the strongest pattern is: persist the encrypted or decrypted ADTS stream to disk immediately with sequence numbers, transcribe later (especially while charging), measure quality from sequence gaps, and optionally offload heavy passes to the user's Mac on the LAN. FluidAudio and Parakeet run about 190× real-time on Apple Silicon Macs.

### Cited Findings
- Omi supports recording on the device without the phone nearby with later sync, and from firmware 3.0.17 offline recordings sync automatically in the background. — [Omi changelog](https://feedback.omi.me/changelog)
- Omi offline sync can stall: a 343 MB Opus SD-card BLE download timed out, and "Offline Sync never makes progress" on a fresh install (user report). — [omi issue #21279](https://github.com/BasedHardware/omi/issues/21279)
- Omi's packet counter is 16-bit and wraps at 65535. Omi splits packets that exceed the MTU into indexed notifications. — [Omi Protocol docs](https://docs.omi.me/doc/developer/Protocol)
- Omi added instrumentation for audio decode failures and could not confirm that every notification is one complete Opus packet. — [omi PR #19546](https://github.com/BasedHardware/omi/pull/19546)
- Real-world battery life falls far short of claims across products:
  - Bee: 1.5–2 days vs 7.
  - Limitless: 6–14 h vs 100.
  - Friend: about 4 h vs 15, per user reports.
  Continuous BLE plus transcription also drained the phone with Bee.
  — [Big Guy on Stuff](https://bigguyonstuff.com/ai-wearables-2026-honest-review/); [mikecann.blog](https://mikecann.blog/posts/always-listening-a-month-with-the-bee-computer-ai-assistant); [heyupnow forum](https://community.heyupnow.com/d/12161-friend--powered-companion-necklace-shipped-but-screw-up)
- FluidAudio ASR runs about 190× real-time on an M4 Pro, and the CLI is macOS-only. — [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio)
- Omi supports a fully self-hosted backend (`.env` local setup), showing that "your own server" processing is a pattern the community uses. — [BasedHardware/omi README](https://github.com/BasedHardware/omi)

### Inferences
Persist first, process later:
- Write every decrypted ADTS frame (or the ciphertext plus seq) to an append-only per-hour file the moment it arrives. At about 32 kbps that is about 4 KB/s, about 14 MB/h, or about 230 MB for a 16 h day.
- Run transcription as a separate consumer of those files, so BLE capture never waits on ML.

Quality metrics per segment, shown as a badge and recorded in the SwiftData event log:
- Packet loss from gaps in the uint32 sequence.
- ADTS frames that fail syncword/length checks after decryption.
- RSSI samples.
- Connection interval and MTU.
- VAD speech ratio.
- A rough SNR from speech-frame vs noise-frame energy.
- ASR average token confidence.
- A "media likelihood" score.

Out of range:
- Rely on CoreBluetooth state restoration and auto-reconnect, which are already working.
- Mark disconnect gaps explicitly in the timeline ("not captured 14:02–14:09") rather than silently.
- On reconnect, re-open the session (SetEncryptionKey → GetSessionNonce) and re-apply the last device state.

Catch-up processing while charging:
- Use BGProcessingTask with `requiresExternalPower`, plus iOS 26's BGContinuedProcessingTask for user-initiated "Process today now" with progress UI. Both APIs need verification against iOS 27 docs.
- The A005 charging event from the Bee can also trigger "Bee is on charger, nothing new will arrive, finalize the day and run the heavy diarization and summary pass".
- Watch `ProcessInfo.thermalState` and Low Power Mode to defer work.

Battery management using Bee states:
- Default to sleep with hardware VAD (state 2) so the Bee only streams on speech.
- Use software VAD (state 4) as a higher-sensitivity option.
- Mute (state 0) on schedule, location or Focus.
- Power off (state 3) on "night".
- Log A004 battery events to estimate drain per mode and show an "estimated hours left" in the widget.
- Measure whether lowering SetBitrate (C008) below 32000 cuts radio time without hurting WER. This needs testing; the firmware may not accept other values.

Button design (A001/A002 are only relayed to the phone; the device does nothing on its own):
- A001 double-press: toggle mute/record, with phone haptic, Watch haptic, Live Activity update and an optional confirmation chime. Alternative: "bookmark the last 2 minutes" (star the moment, prioritize its transcription and summary, include it in the digest).
- A002 hold: "voice note / command". The next utterance (until silence or EOU) is parsed by the on-device LLM into an action, such as a Reminder (EventKit), a Calendar event, or a note. This mirrors Bee's post-Amazon voice-note button and email/calendar actions, but done locally.
- Make the mapping configurable, and expose each action as an App Intent so Shortcuts can rebind it.

iOS surfaces:
- Live Activity / Dynamic Island: state (recording, muted, VAD-sleep), minutes captured today, live loss %, Bee battery, plus interactive Mute and Bookmark buttons via App Intents.
- Control Center and Lock Screen control for Mute.
- Home and Lock Screen widgets: today's digest, pending reviews, battery.
- Apple Watch: complication with state and a mute toggle, and haptics for button events.
- App Intents and Shortcuts: Mute Bee, Unmute, Bookmark, Ask Bee, "What did I commit to today?", Export day.
- Reminders and Calendar via EventKit: write only accepted to-dos to a "FreeBee" list, with optional two-way sync like Omi. Use calendar events to name conversations and pre-seed speaker names from attendees.

Mac offload (local network only, opt-in):
- The iPhone discovers the user's Mac via Bonjour (Network.framework) and pairs once using a QR or shared key.
- It ships the day's ADTS/AAC files over an encrypted local channel (TLS with pinned key, or Noise).
- The Mac runs the existing beekit pipeline (mlx-whisper large-v3-turbo, pyannote/FluidAudio diarization, a bigger local LLM through MLX) and returns JSON transcripts and summaries.
- Refuse to send unless the Mac is on the same LAN, and show "Processed on <Mac name>" provenance in the UI.
- The iPhone stays the system of record, and the Mac is stateless or deletes after return.

Codec and framing defensive measures (lessons from Omi's codec bugs):
- Version the parser by firmware version (0.6.1) and codec ID (C006 codec 1 = AAC).
- Keep discarding the first 3 frames as the official app does.
- Add a decode-failure counter to the event log.

### Gaps
- Whether the Bee Pioneer has any onboard flash buffer or offline-record mode, which would allow Omi-style sync after reconnect, is unknown. Nothing found in public sources, and our PROTOCOL.md doesn't establish it.
- Accepted SetBitrate values beyond 32000 and their battery effect are untested.
- No public measurements were found of iPhone 17 Pro battery cost for continuous BLE audio plus on-device ASR.
- iOS 27 specifics for BGContinuedProcessingTask, Live Activity limits, and the Control Center control APIs were not checked against Apple docs in this pass.
- No prior-art product was found that offers "offload to your own Mac" for a wearable. The closest are Omi's self-hostable backend and Hyprnote's local LLM endpoints (Ollama, LM Studio).
