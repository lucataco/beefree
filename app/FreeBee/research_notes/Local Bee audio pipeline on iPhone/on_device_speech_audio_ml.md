# On-device speech-to-text, VAD, diarization and enhancement on iPhone 17 Pro (iOS 27) for Bee ambient audio

Research date: 2026-10-20. Target: iPhone 17 Pro (A19 Pro), iOS 27.0.1, Xcode 27.1. Input: 16 kHz mono AAC-LC (ADTS) at about 32 kbps, far-field, noisy, multi-speaker, all-day capture.

Versions checked against GitHub on 2026-10-20 (via GitHub API):
- Argmax OSS Swift SDK (formerly WhisperKit) v1.1.1, published 2026-10-08, MIT — [GitHub releases](https://github.com/argmaxinc/argmax-oss-swift/releases)
- FluidAudio v0.17.7 (tag commit 2026-10-08), Apache-2.0; repo pushed 2026-10-21 — [GitHub](https://github.com/FluidInference/FluidAudio), [tags](https://github.com/FluidInference/FluidAudio/tags)
- whisper.cpp v1.9.5, published 2026-10-06, MIT — [GitHub releases](https://github.com/ggml-org/whisper.cpp/releases)
- Silero VAD v6.2.3, published 2026-09-23, MIT — [GitHub releases](https://github.com/snakers4/silero-vad/releases)
- pyannote-audio 4.0.7, published 2026-06-30, MIT (code) — [GitHub releases](https://github.com/pyannote/pyannote-audio/releases)
- Moonshine repo v0.1.5, published 2026-08-24; GitHub reports license "NOASSERTION" — [GitHub](https://github.com/moonshine-ai/moonshine)
- DeepFilterNet upstream repo last pushed 2024-10-17 (stale) — [GitHub](https://github.com/Rikorose/DeepFilterNet)
- LocalVQE (Apache-2.0) repo pushed 2026-10-19 — [GitHub](https://github.com/localai-org/LocalVQE)

## 1. Apple SpeechAnalyzer / SpeechTranscriber / DictationTranscriber (iOS 26, plus iOS 27 changes)

### Takeaway
SpeechAnalyzer (iOS 26) is a solid, free, system-managed on-device long-form transcriber. Its accuracy is about the same as mid-size Whisper (Argmax: 14.0% WER on earnings calls, between whisper-base and whisper-small; Parakeet v2 was 11.7%) and it is fast. iOS 27 (June 2026) added only input helpers (file/capture input providers and a buffer converter). It still has **no speaker diarization or speaker attributes**, and the only per-token attributes are time ranges and confidence. Custom vocabulary exists through AnalysisContext and SFSpeechLanguageModel. Model assets download from Apple's servers once and then run offline.

### Cited Findings
- **Framework structure:** SpeechAnalyzer manages a session and hosts modules. SpeechTranscriber is "appropriate for normal conversation and general purposes." DictationTranscriber is "similar to system dictation features and compatible with older devices." SpeechDetector does VAD. — [Apple Speech docs](https://developer.apple.com/documentation/speech)
- **iOS availability:** SpeechAnalyzer, SpeechTranscriber, SpeechDetector, DictationTranscriber, AnalysisContext and AssetInventory are all marked "introduced iOS 26.0." — [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer), [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- **What changed in iOS 27:** Apple's "Speech updates" page has one "June 2026" entry. It adds `AssetInputSequenceProvider` (file or asset input) and `CaptureInputSequenceProvider` (mic or capture-device input), and `AnalyzerInputConverter` (converts `AVAudioBuffer` to formats `AnalyzerInput` supports). All three are marked iOS 27.0. No diarization, speaker-label or new-language items are listed. — [Speech updates](https://developer.apple.com/documentation/updates/speech), [AssetInputSequenceProvider](https://developer.apple.com/documentation/speech/assetinputsequenceprovider)
- **Feeding raw buffers is supported:** You can build an async sequence of `AnalyzerInput` from your own buffers. Use `bestAvailableAudioFormat(compatibleWith:)` to pick the target format, or convert on the fly with `AnalyzerInputConverter`. An analyzer "can only analyze one input sequence at a time." — [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- **Result options:** Presets are `transcription`, `transcriptionWithAlternatives`, `timeIndexedTranscriptionWithAlternatives`, `progressiveTranscription` and `timeIndexedProgressiveTranscription`. The only `ResultAttributeOption` values are `audioTimeRange` and `transcriptionConfidence`, so there is no speaker attribute. — [Preset](https://developer.apple.com/documentation/speech/speechtranscriber/preset), [ResultAttributeOption](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption)
- **Custom vocabulary:** The Speech docs have a "Custom vocabulary" topic group: `AnalysisContext` (with `contextualStrings`), `SFSpeechLanguageModel`, `SFSpeechLanguageModel.Configuration` and `SFCustomLanguageModelData`. `SpeechAnalyzer.setContext(_:)` applies the context. — [Speech docs](https://developer.apple.com/documentation/speech), [AnalysisContext](https://developer.apple.com/documentation/speech/analysiscontext). This conflicts with secondary sources: Argmax's June 2025 post says SpeechAnalyzer "lacks custom vocabulary" ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)), and a dev.to post says there is no equivalent to contextualStrings in iOS 26.0 ([dev.to](https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5)). Another source says contextualStrings applies to the DictationTranscriber path. Treat this as unverified for SpeechTranscriber.
- **Model download and offline use:** Assets are "machine-learning models downloaded from Apple's servers and managed by the system." Once installed they "persist between app launches and are shared between apps," and the system updates them automatically. Apps get a limited number of locale reservations (`maximumReservedLocales`). The system "may unsubscribe your app from assets that haven't been used in a while." — [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory). Argmax also notes the model "is not pre-installed and downloads on first use." — [Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
- **SpeechDetector (VAD):** It gates transcription "by the presence of voices, saving power," has a `SensitivityLevel` (medium recommended), and "only functions in conjunction with a SpeechTranscriber or DictationTranscriber module." Apple warns aggressive VAD can drop real speech. — [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)
- **Argmax benchmark (vendor-run, June 20, 2025, M4 Mac mini, macOS 26 beta 1, 10% subset of earnings22 ≈ 12 h):**

  | System | WER | Speed factor |
  |---|---|---|
  | WhisperKit whisper-base.en | 15.2 | 111 |
  | Apple SpeechTranscriber | 14.0 | 70 |
  | WhisperKit whisper-small.en | 12.8 | 35 |
  | Argmax Pro parakeet-v2 | 11.7 | 359 |

  Argmax says Apple's model "matches mid-tier Whisper models on long-form conversational transcription." It lists Apple at 10 languages versus 100 for WhisperKit. — [Argmax blog](https://www.argmaxinc.com/blog/apple-and-argmax)
- **MacStories hands-on (June 2025, macOS Tahoe beta, one 34-minute file):** Yap (built on SpeechTranscriber) took 0:45. MacWhisper Large V3 Turbo took 1:41, VidCap 1:55, and MacWhisper Large V2 3:55. That is about 2.2x faster than Large V3 Turbo with "no noticeable difference in transcription quality" (judged informally). All tools struggled with proper nouns. — [MacStories](https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/)
- **Languages:** Argmax counted 10 languages in June 2025 ([Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)). A Japanese tech blog says roughly 40 locales ([issoh.co.jp](https://www.issoh.co.jp/tech/details/8929/)). These conflict and the second is secondary. Developers report `supportedLocales` returns an empty array on the Simulator.
- **WWDC26 sessions:** None of the 138 WWDC26 sessions on Apple's video index is about the Speech framework. ML sessions focus on Foundation Models and the new **Core AI** framework ("Meet Core AI", "Integrate on-device AI models into your app using Core AI", "Dive into Core AI model authoring and optimization"). — [WWDC26 videos](https://developer.apple.com/videos/wwdc2026/), [Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/)

### Inferences
- For FreeBee, SpeechTranscriber is a good **zero-download-cost fallback or baseline**: no bundled model, no license issues, Apple-maintained, with word time ranges and confidence. On noisy multi-speaker audio it is likely less accurate than Parakeet TDT v3/Ultra, judging by the earnings22 gap (14.0 vs 11.7 WER for Parakeet v2). Diarization still needs a separate model.
- Our decoded PCM (AAC → Float32 16 kHz) can go straight into `AnalyzerInput` via `AnalyzerInputConverter` (iOS 27). No file round-trip is needed.
- iOS 27 brought no new speech-model capability, so the "accuracy vs Whisper" picture from 2025 benchmarks probably still holds. Apple can update assets silently, so re-benchmark on device.

### Gaps
- No independent, rigorous WER benchmark of SpeechTranscriber on far-field or meeting data (AMI, CHiME), and none on iPhone hardware. Published numbers are Argmax's (vendor) and MacStories' (informal, Mac).
- Whether SpeechTranscriber keeps running when the app is backgrounded (for example, kept alive by bluetooth-central) is not documented by Apple. No authoritative source found.
- Exact iOS 27 `supportedLocales` count not found. Query it on device.
- Whether `contextualStrings` or `SFSpeechLanguageModel` affect SpeechTranscriber (not just DictationTranscriber) is unconfirmed.
- No RTF, memory or energy numbers for SpeechTranscriber on A19 Pro.

## 2. WhisperKit (Argmax) with whisper-large-v3-turbo / distil variants; SpeakerKit; Parakeet in Argmax

### Takeaway
WhisperKit became the **Argmax Open-Source SDK** (MIT; v1.0.0 on 2026-05-01, now v1.1.1 on 2026-10-08). It bundles WhisperKit, SpeakerKit (open-source pyannote-4 / community-1 diarization since v0.17.0, March 2026), TTSKit and ArgmaxCore. The open-source SDK covers Whisper only. Parakeet, Sortformer, real-time speaker-attributed transcription and large custom vocabularies are in the **paid Argmax Pro SDK 2** (GA April 7, 2026). Whisper is the best choice for languages outside Parakeet's 25 European languages, but it is slower than Parakeet on the ANE.

### Cited Findings
- **Releases (GitHub, dates via API):**
  - v1.1.1 (2026-10-08): bug and crash fixes; `inputDeviceID` for `AudioStreamTranscriber`.
  - v1.1.0 (2026-08-06): "Incremental file loading cuts peak memory by 70%+ for 3-hour audio"; SpeakerKit speaker centroid embeddings for matching speakers across separate diarization runs.
  - v1.0.0 (2026-05-01): rename to Argmax Open-Source SDK (WhisperKit + SpeakerKit + TTSKit + ArgmaxCore), Swift 6 concurrency, CLI renamed `argmax-cli` with local streaming server.
  - v0.18.0 (2026-04-01): SpeakerKit refactor, lazy model load.
  - v0.17.0 (March 13): SpeakerKit with pyannote 4 (community-1), RTTM export, `--diarization` flag.
  - The package still declares iOS 16 / macOS 13. TTSKit needs iOS 18.

  — [Argmax OSS releases](https://github.com/argmaxinc/argmax-oss-swift/releases). The repo license is MIT (GitHub API).
- **Pro SDK 2 (April 7, 2026):** Real-time transcription with speaker labels, NVIDIA Parakeet and Whisper streaming, NVIDIA Sortformer diarization, custom vocabulary up to 3,000 keywords, Android support, 14-day trial. Pricing is not public. On CALLHOME it claims a better cpWER than Deepgram (numbers shown only in a chart). — [Argmax Pro SDK 2](https://www.argmaxinc.com/blog/argmax-sdk-2)
- **SpeakerKit Pro (March 7, 2025 post, older):** About 10 MB of models. Diarizes 4 minutes of audio in about 1 s on iPhone (a 6:22 file in about 2 s). Claims to match pyannote's error rate across 13 datasets (no DER numbers in the post). At that time, speaker identification (voiceprints across contexts) was listed as an "upcoming feature." — [Argmax SpeakerKit](https://www.argmaxinc.com/blog/speakerkit)
- **WhisperKit paper (ICML 2025 workshop, July 2025):** 2.2% WER and 0.46 s latency for streaming, compared against gpt-4o-transcribe, Deepgram nova-3 and Fireworks large-v3-turbo. Devices are not stated in the abstract. — [arXiv 2507.10860](https://arxiv.org/abs/2507.10860)
- **Model size and accuracy trade-off:** WhisperKit's HF eval table lists a compressed large-v3-turbo at about 954 MB (WER 2.47) versus about 3,100 MB uncompressed (WER 2.03), on its LibriSpeech-style eval. — [argmaxinc/whisperkit-coreml README](https://huggingface.co/argmaxinc/whisperkit-coreml/blob/20f51f218879660aa966596dfe336a762249abe8/README.md)
- **Whisper speed versus Parakeet (Mac, vendor):** whisper-small.en at 35x and whisper-base.en at 111x, versus Parakeet v2 (Pro SDK) at 359x on an M4 Mac mini. — [Argmax](https://www.argmaxinc.com/blog/apple-and-argmax)
- **Long-form leaderboard context:** On the Open ASR long-form track, Whisper Large v3 had the best open-model WER (6.43) but RTFx 68.56, versus Parakeet CTC 1.1B at 6.68 WER and 2,793.75 RTFx (GPU). — [HF Open ASR blog, Nov 21, 2025](https://huggingface.co/blog/open-asr-leaderboard)

### Inferences
- Use the open-source Argmax SDK if you need Whisper-class multilingual coverage (99 languages) or want SpeakerKit (pyannote community-1, with centroid embeddings for cross-session matching). Parakeet in Argmax needs a Pro license, but FluidAudio offers Parakeet free (see section 3).
- large-v3-turbo (about 954 MB compressed) is feasible on an iPhone 17 Pro. It is several times slower per audio hour than Parakeet TDT. That is acceptable for batch overnight processing but costlier for incremental background processing.
- The 70% peak-memory cut for 3-hour files (v1.1.0) matters for all-day audio. Still prefer VAD-segmented chunks over one giant file.

### Gaps
- No published WhisperKit RTF, memory or energy numbers for iPhone 17 Pro / A19 Pro. The HF benchmark dashboard (argmaxinc/whisperkit-benchmarks) has device rows, but no A19 Pro speed data was retrieved.
- No public DER figures for open-source SpeakerKit versus FluidAudio's pyannote port on identical data.
- Argmax Pro pricing is not public.
- The distil-whisper large-v3.5 status on WhisperKit was not verified.

## 3. NVIDIA Parakeet TDT (v2/v3) via FluidAudio; Moonshine; whisper.cpp; 2026 Open ASR leaders that run on-device

### Takeaway
**FluidAudio + Parakeet TDT 0.6B v3 (or the "Ultra" post-train)** is the strongest free option on iPhone today. It runs on the ANE, covers 25 European languages, gets 2.1–2.5% WER on LibriSpeech clean, 11.31% on AMI and 11.42% on Earnings-22 (NVIDIA card), and runs at about 110–190x real time on M-series Macs. It has word-level timestamps, a pure-Swift SPM package, an Apache-2.0 SDK and CC-BY-4.0 weights. Open ASR leaders in 2026 (Granite Speech, Cohere Transcribe, Canary-Qwen, Qwen3-ASR) are 1.7–8B-parameter LLM-decoder models. Most are too big or slow for phone background use, except a FluidAudio Cohere Transcribe port (1.8 GB int8 encoder, 14 languages). whisper.cpp (v1.9.5) is maintained, but its fast paths are Metal/GPU, which suits background work poorly on iPhone.

### Cited Findings
- **Parakeet TDT 0.6B v3 (NVIDIA card):**
  - Released 2025-08-14; 0.6B parameters; 25 European languages; CC BY 4.0.
  - Word-, segment- and char-level timestamps.
  - Long audio: up to 24 min with full attention on an A100, or up to 3 h with local attention.
  - Open ASR WER: average 6.34%; AMI 11.31%; Earnings-22 11.42%; GigaSpeech 9.59%; LibriSpeech clean 1.93% / other 3.59%; TED-LIUM 2.75%.
  - Noise robustness (MUSAN, average WER): clean 6.34%; SNR 10 dB 7.12%; 5 dB 8.23%; 0 dB 11.66%; -5 dB 19.88%.
  - Multilingual: FLEURS 11.97%, MLS 7.83%.

  — [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- **FluidAudio model lineup (v0.17.x):**
  - Parakeet TDT v3 is the default.
  - Parakeet Ultra is "recommended": moondream post-train of v3, int8 encoder 595 MB, ANE, iOS 17+. LibriSpeech clean 2.13% vs 2.27%, other 3.81% vs 4.12%, FLEURS 24-language mean 11.67% vs 14.81%.
  - Parakeet Redux: 2-bit, about 220 MB, iOS 18+.
  - Phonon-2: English, iOS 18+.
  - TDT v2: English only.
  - TDT-CTC-110M: 3.01% WER on clean, 96.5x on M2.
  - Parakeet EOU 120M for streaming; Nemotron Speech Streaming 0.6B (English and multilingual).
  - Cohere Transcribe (14 languages, 1.8 GB int8 encoder, iOS 18+, 35 s per-call cap).
  - SenseVoice (50+ languages) and Paraformer (Mandarin).

  — [FluidAudio Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)
- **FluidAudio ASR benchmarks (Apple-silicon Macs):**
  - v3 / Ultra / Phonon-2 on M5 Pro (ANE), LibriSpeech clean: 2.27 / 2.13 / 2.47% at about 149–159x RTFx.
  - On a 60-min Earnings-22 file: 16.5 / 13.5 / 17.2% WER at 335x / 457x / 480x.
  - v3 FLEURS 25 languages: 14.7% average.
  - Parakeet EOU at 320 ms chunks (M2): 4.88% WER at 19.25x.
  - Nemotron Streaming 2240 ms (M5 Pro): 2.46% at 93.6x.
  - The README cites about 190x RTFx on M4 Pro.
  - The page notes minor internal inconsistencies, such as v3 clean WER listed as both 2.5% and 2.6%.

  — [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md), [FluidAudio README](https://github.com/FluidInference/FluidAudio)
- **iPhone-specific FluidAudio data:**
  - parakeet-tdt-0.6b-v3 Core ML encoder load is 3,361 ms cold and 162 ms warm on iPhone 16 Pro Max (4,396 ms cold on iPhone 13).
  - The Parakeet Unified int8 encoder fails to load on A16, so use fp16 on iOS (issue #828).
  - Nemotron on iOS: the CPU encoder (about 140 MB, about 66x RTFx) was about 2x faster than 4-way ANE sharding (about 33x).

  — [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- **Compute placement and background:** The Parakeet v3 encoder defaults to `.cpuAndNeuralEngine`. GPU is about 8% faster on Mac and WER-neutral, but "ANE remains the default for power efficiency on iOS." FluidAudio recommends Ultra because it "runs on the ANE (so iOS background transcription works)." The README says the models are "optimized for background processing, ambient computing and always on workloads." — [EncoderComputePlacement.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/EncoderComputePlacement.md), [ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md), [README](https://github.com/FluidInference/FluidAudio)
- **Long-form chunking in FluidAudio:**
  - Fixed 15 s encoder window (240,000 samples) with at least 480 ms seam overlap.
  - Optional "encoder ladder" pause-cut windows improved 1-h Earnings-22 WER from 17.20% to 16.68%.
  - ANE time is quantized in 64-frame tiles (10 s costs 12 ms, 11–15 s costs about 19 ms on M5 Pro).

  — [LongTranscription.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/LongTranscription.md)
- **Custom vocabulary in FluidAudio:** For the 0.6B TDT models, a separate 97.5 MB CTC-110M encoder runs keyword spotting and rescoring at 25.98x RTFx with about 130 MB peak memory. With TDT-CTC-110M the built-in CTC head is about 1 MB at 70x and about 67 MB peak. — [CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)
- **Integration:** SPM `.package(url: "https://github.com/FluidInference/FluidAudio.git", ...)`. Package traits trim the build (for example, ASR+VAD only, or add `"Diarizer"`). Swift 6 required; traits need Swift 6.2 / Xcode 26+. Models download from Hugging Face on first use, or can be staged locally. — [FluidAudio README](https://github.com/FluidInference/FluidAudio)
- **Licensing nuance:** FluidAudio code is Apache-2.0. The README calls the models MIT/Apache, but the upstream Parakeet v3 weights are CC BY 4.0 (attribution required) and Sortformer is under the NVIDIA Open Model License. — [FluidAudio README](https://github.com/FluidInference/FluidAudio), [NVIDIA card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- **Open ASR Leaderboard 2026:**
  - A May 2026 aggregator snapshot lists IBM Granite Speech 4.1 2B at 5.33 average WER, Cohere Transcribe 03-2026 at about 5.42, Canary-Qwen-2.5B 5.63, Granite Speech 3.3 8B 5.74 and Qwen3-ASR-1.7B 5.76. This is a secondary aggregator, so verify on the HF space. — [benchmarklist](https://benchmarklist.com/benchmarks/open_asr_leaderboard/)
  - The leaderboard's own write-up says Conformer+LLM models lead English WER but lag in speed, while CTC/TDT decoders give "10–100× faster throughput" at slightly higher WER. — [HF blog](https://huggingface.co/blog/open-asr-leaderboard), [Open ASR paper](https://arxiv.org/html/2510.06961v1)
- **Moonshine v2 (Feb 12, 2026):** A streaming encoder with sliding-window attention, claiming accuracy "on-par with models 6x their size while running significantly faster." A Moonshine-hosted copy says "4x… 3x–8x faster", so the sources conflict. — [arXiv 2602.12241](https://arxiv.org/abs/2602.12241). A community card lists Moonshine Streaming Tiny at 34M parameters, English only, with an 80 MB ONNX INT8 variant (third party). — [HF card](https://huggingface.co/felixem/moonshine-streaming-tiny-optimized)
- **whisper.cpp:** v1.9.5 released 2026-10-06, actively maintained, MIT (GitHub API). — [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases)

### Inferences
- **Primary ASR recommendation:** FluidAudio Parakeet **Ultra** (or v3) for batch/offline transcription of VAD segments. It has the best accuracy-per-joule on ANE, 25 languages, timestamps for diarization alignment, a free license (keep CC-BY attribution in the app's About screen), and the same vendor as our VAD and diarization models (one dependency).
- The 15 s fixed encoder window suits VAD-segmented conversations. The pause-cut ladder helps long monologues.
- If the user speaks languages outside Parakeet's 25, fall back to Apple SpeechTranscriber (system-managed) or WhisperKit large-v3-turbo.
- Moonshine v2 is attractive only for ultra-low-latency live captions (tiny English models). No Swift/CoreML first-party SDK was verified, so it is lower priority for us.
- whisper.cpp offers no advantage over WhisperKit/FluidAudio on iOS because its acceleration is Metal/GPU-centric, and GPU work is restricted in the background (see section 7).

### Gaps
- **No measured Parakeet RTFx on A19 Pro / iPhone 17 Pro** was found. All throughput numbers are M-series Macs. iPhone numbers for v3 cover only model load times.
- No WER data on AAC-compressed far-field wearable audio for any of these models.
- Moonshine v2 WER tables and license terms (GitHub says "NOASSERTION") were not retrieved.
- The current Open ASR Leaderboard ranking was not read from the primary HF space (it is a Gradio app). Figures above are from an aggregator.

## 4. VAD: Silero VAD (CoreML), FluidAudio VAD, Apple SpeechDetector/SoundAnalysis; segmenting all-day audio

### Takeaway
Use **Silero VAD v6.2.x via FluidAudio's `VadManager`**. It runs CPU-only, at over 1,000x real time with 256 ms hops. It has Silero-reference segmentation (min speech, min silence, padding, max-duration split) and streaming hysteresis. On noise-heavy sets it has high false-positive rates (about 30% on MUSAN noise in one config), so add a second-level "conversation" segmenter on top (gap-based merging plus speech-density thresholds). Apple's SpeechDetector can only be used inside a SpeechTranscriber/DictationTranscriber session, so it can't serve as a standalone VAD.

### Cited Findings
- **FluidAudio VAD:** Ships Silero VAD (256 ms unified Silero v6.2.1 Core ML artifact) with Silero-style timestamp extraction and streaming hysteresis. `segmentSpeech` / `segmentSpeechAudio` return speech intervals or clips with `minSpeechDuration`, `minSilenceDuration`, `speechPadding` and max-duration splitting. Example uses `computeUnits = .cpuOnly` and a manual model-staging path with no network. — [FluidAudio VAD GettingStarted](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/VAD/GettingStarted.md)
- **VAD benchmarks (FluidAudio):**

  | Model | Test set | Hardware | Result | RTFx |
  |---|---|---|---|---|
  | Silero v6.2.1 | mini50 | M1 Air | acc 94.0%, precision 89.3%, recall 100%, F1 94.3% | 1,078x |
  | Silero | VOiCES subset (thr 0.85) | — | F1 97.9% | 1,231x |
  | Silero | MUSAN full, 2,016 files (thr 0.8) | — | acc 94.2%, recall 78.9%, F1 85.2% | 1,221x |
  | Silero | MUSAN noise, 774 clips | — | 69.8% specificity (30.2% false positives) | — |
  | FSMN-VAD (alternative) | MUSAN noise, 774 clips | — | 81.9% specificity (18.1% false positives) | 571x |

  — [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- **Silero VAD upstream:** v6.2.3 (2026-09-23), MIT license (GitHub API). — [silero-vad releases](https://github.com/snakers4/silero-vad/releases)
- **Apple SpeechDetector:** Works only with a transcriber module, and has a sensitivity trade-off between power and dropped speech. — [SpeechDetector](https://developer.apple.com/documentation/speech/speechdetector)
- **Parakeet EOU:** FluidAudio's streaming EOU model (120M) adds end-of-utterance detection if a live, turn-aware path is needed. — [Models.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md)

### Inferences
- **Proposed two-level segmentation for all-day audio:**
  1. Frame VAD (Silero, 256 ms hops) on decoded PCM as packets arrive. This is cheap enough on CPU in the background.
  2. Utterance segments (min speech about 0.25–0.5 s, min silence about 0.4–0.8 s, padding about 0.1–0.2 s, max segment 15 s to match the Parakeet window).
  3. "Conversation" sessions: merge utterances separated by less than about 30–120 s of non-speech. Close a conversation after a longer gap (for example, 2–5 min), or on device events (A003 state change, mute), or when the dominant speaker set changes.
  4. Drop conversations under a minimum total speech (for example, under 10 s) or with low VAD density, to filter TV and background chatter false positives.

  These thresholds are our heuristics and need tuning on real Bee captures.
- Because Silero's false-positive rate rises in noise, a far-field wearable in noisy places will produce some non-speech segments. Downstream ASR confidence (Parakeet token confidences, or SpeechTranscriber `transcriptionConfidence`) can be used as a second filter.
- The Bee firmware also offers hardware/software VAD sleep states (states 2/4 in our protocol). Using device-side VAD would cut BLE and phone work, but its accuracy is unknown. Keep phone-side Silero as the authority.
- Apple SoundAnalysis (built-in sound classifier) could tag non-speech ambience (music, TV, traffic) for context. It was not researched in depth here.

### Gaps
- No published Silero/FluidAudio VAD accuracy on 32 kbps AAC far-field audio.
- No authoritative "conversation segmentation" method for lifelogging audio was found. The heuristics above are inferences.
- Apple SoundAnalysis classifier accuracy and iOS 27 changes were not researched (out of time budget).

## 5. Diarization and speaker recognition on-device (FluidAudio pyannote / LS-EEND / Sortformer / Nemotron-3, SpeakerKit); enrolling the wearer

### Takeaway
For recorded conversations, run **pyannote community-1 offline (FluidAudio `OfflineDiarizerManager`, or Argmax SpeakerKit)**. It is the most accurate open option: about 10.6% DER on AMI-SDM in FluidAudio's port at 323x on M5 Pro, and 19.9% AMI-SDM in pyannote's no-collar protocol. Then do speaker identification yourself: extract 256-d WeSpeaker embeddings per speaker cluster and match them by cosine distance against an enrolled "wearer" voiceprint and a growing gallery of known contacts. FluidAudio's `SpeakerManager` (streaming pipeline), LS-EEND `enrollSpeaker`, and Argmax's v1.1.0 centroid embeddings all support this pattern. Streaming diarizers (Sortformer at 4 speakers, Nemotron-3 at 8, LS-EEND up to 10) suit live UX but have worse DER.

### Cited Findings
- **pyannote community-1 (CC-BY-4.0, benchmark updated 2025-09), DER %, no collar, overlap included:**

  | Dataset | 3.1 | community-1 | precision-2 (cloud only) |
  |---|---|---|---|
  | AMI SDM | 22.7 | 19.9 | 15.6 |
  | AMI IHM | 18.8 | 17.0 | 12.9 |
  | DIHARD 3 | 21.4 | 20.2 | 14.7 |
  | Ego4D (egocentric) | 51.2 | 46.8 | 39.0 |
  | MSDWild | 25.4 | 22.8 | 17.3 |
  | VoxConverse | 11.2 | 11.2 | 8.5 |
  | CALLHOME | 28.5 | 26.7 | 16.6 |

  It adds an "exclusive" (non-overlapping) diarization output that simplifies aligning with ASR word timestamps. It uses WeSpeaker embeddings and VBx clustering. — [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)
- **FluidAudio diarization benchmarks:**

  | Pipeline | Dataset | Hardware | DER | RTFx |
  |---|---|---|---|---|
  | Offline community-1 port | AMI SDM, 16 meetings | M5 Pro | 10.6% (JER 17.4%) | 323x |
  | Offline community-1 port | VoxConverse | — | 13.9–15.1% | 65–122x |
  | Streaming pyannote 3.1 + WeSpeaker, 10 s chunks | AMI SDM | — | 38.2% | 207x |
  | Streaming pyannote 3.1 + WeSpeaker, 3 s chunks | AMI SDM | — | 53.3% | — |
  | Sortformer streaming (highContextV2_1) | AMI SDM | — | 26.4% | 835x |
  | LS-EEND (ami variant) | AMI SDM | M4 Max CPU | 20.7% | 74.5x |

  The AMI re-run is dated 2026-07-03. FluidAudio's scoring protocol differs from pyannote's, so 10.6% vs 19.9% is not like-for-like. — [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- **NVIDIA Streaming Sortformer 4spk v2.1 (NVIDIA Open Model License):**
  - Maximum 4 speakers; "performance degrades on recordings with 5 and more speakers."
  - DER: AMI SDM 17.80% (30.4 s latency) / 20.57% (1.04 s); CALLHOME full 10.10 / 11.19%; DIHARD III full 19.49 / 20.21%.
  - Trained mainly on English. May degrade on noisy or very long recordings.
  - A successor, Nemotron-3-Diarization, supports 8 speakers.

  — [nvidia/diar_streaming_sortformer_4spk-v2.1](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)
- **Nemotron-3 Diarization in FluidAudio:**
  - Up to 8 speakers at 10 ms resolution.
  - Presets: `fast32` (190 MB, 2.88 s latency) is the recommended default; `s32-split-w8a8` (95 MB) is "100% ANE-resident graph, zero GPU use — the iOS pick"; `offline` is GPU-only.
  - Models are gated on HF until NVIDIA's public release.

  — [FluidAudio Nemotron3.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Nemotron3.md)
- **LS-EEND in FluidAudio:**
  - Up to 10 speakers; recordings up to 1 h; operates at 8 kHz.
  - DER: AMI 20.76%, CALLHOME 12.11%, DIHARD III 19.61%.
  - "Speaker identity is local to the recording; persistent speaker enrollment may be unreliable."
  - Provides `enrollSpeaker(withAudio:named:)` to warm the session with a known speaker.

  — [FluidAudio LS-EEND.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/LS-EEND.md)
- **FluidAudio SpeakerManager:**
  - In-memory speaker database with 256-d embeddings and cosine-distance assignment.
  - Defaults: `speakerThreshold` 0.65, `embeddingThreshold` 0.45, `minSpeechDuration` 1.0 s, `minEmbeddingUpdateDuration` 2.0 s.
  - Supports `initializeKnownSpeakers` with reset, merge, overwrite or skip modes.
  - Works only with the streaming `DiarizerManager`, not `OfflineDiarizerManager` (which uses VBx).

  — [SpeakerManager.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/SpeakerManager.md), [FluidAudio docs](https://docs.fluidinference.com/diarization/speaker-manager). The README notes the WeSpeaker/pyannote pipeline makes "speaker pre-enrollment and speaker database management easier." Sortformer has no speaker persistence across recordings. — [FluidAudio README](https://github.com/FluidInference/FluidAudio)
- **Argmax SpeakerKit (open source):** pyannote 4 / community-1 since v0.17.0 (2026-03-13). v1.1.0 (2026-08-06) exposes speaker centroid embeddings "for matching speakers across separate diarization runs." — [Argmax OSS releases](https://github.com/argmaxinc/argmax-oss-swift/releases)

### Inferences
- **Wearer enrollment plan:**
  1. Record 30–60 s of the wearer's voice through the Bee itself (same mic and codec chain), across a few sessions and environments.
  2. Compute WeSpeaker embeddings over VAD segments and store the mean plus several exemplars.
  3. After each offline diarization run, compute per-cluster centroids and label the cluster nearest the wearer (cosine distance under a tuned threshold, starting around FluidAudio's 0.65 default) as "Me."
  4. Others are matched against a gallery of named contacts the user labels in the UI, or kept as "Speaker N" and auto-added when long enough.

  The wearer is the closest talker to the mic, so their segments will have higher SNR and level. Energy features can back up embedding matches.
- Ego4D (egocentric) DER of about 47% for community-1 shows that wearable or egocentric audio is much harder than meetings. Expect DER well above AMI numbers on Bee audio. The "Me versus not-me" split is the most reliable and valuable output. Fine-grained multi-party attribution will be noisier.
- Run diarization per conversation, not per day. Pyannote clustering scales poorly and speaker counts are local. LS-EEND caps at 1 h.
- Use pyannote's "exclusive" diarization output to assign each Parakeet word timestamp to one speaker.

### Gaps
- No DER numbers for any on-device diarizer on body-worn, far-field, 32 kbps AAC audio.
- No published speaker-verification EER for FluidAudio's WeSpeaker Core ML embeddings, and no recommended enrollment duration.
- Open-source SpeakerKit DER versus FluidAudio's port on the same protocol is not published.
- Nemotron-3 Diarization DER numbers and public-release status were not found (models gated).

## 6. Audio enhancement / noise suppression before ASR (Apple Voice Isolation, DeepFilterNet, LocalVQE) — is it worth it?

### Takeaway
**Not by default.** Two 2025–2026 studies found speech enhancement before modern ASR (Whisper, Parakeet) *raised* WER in every condition tested, even when perceptual quality improved. Feed Parakeet/Whisper the decoded audio directly (Parakeet v3 degrades gracefully: 6.34% → 8.23% WER at 5 dB SNR). Apply enhancement only to a *listening/playback* copy, or A/B test it on your own Bee data. Apple's `AUSoundIsolation` audio unit (iOS 16+) and FluidAudio's LocalVQE (beta) are the available on-device options. DeepFilterNet's upstream repo has been inactive since Oct 2024.

### Cited Findings
- **Medical ASR study (arXiv 2512.17562, Dec 2025):** MetricGAN+ denoising on 500 recordings × 9 noise conditions lowered accuracy for Whisper, NVIDIA Parakeet, Gemini Flash 2.0 and Parrotlet-a in **every** condition. The Gaussian-noise case moved semantic WER from 11% to 58%. The authors suggest modern ASR has internal noise robustness and that enhancement artifacts confuse recognizers. — [arXiv 2512.17562](https://arxiv.org/abs/2512.17562v1)
- **SAM-Audio study (arXiv 2603.04710, March 2026):** Using SAM-Audio as preprocessing for zero-shot Whisper raised WER and CER on Bengali and English noisy sets, although signal-quality metrics improved. The degradation grew with Whisper model size. — [arXiv 2603.04710](https://arxiv.org/abs/2603.04710)
- **Parakeet v3 noise robustness:** Average WER 6.34% clean → 7.12% at 10 dB → 8.23% at 5 dB → 11.66% at 0 dB → 19.88% at -5 dB (MUSAN). — [NVIDIA card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- **Apple:** `kAudioUnitSubType_AUSoundIsolation` (Apple's voice-isolation audio unit) is available from iOS 16.0. — [Apple docs](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation). Apple publishes no WER effect.
- **FluidAudio LocalVQE (beta):** A DeepVQE derivative (Apache-2.0) for AEC, noise suppression and dereverb at 16 kHz. v1.3 has 4.8M parameters at 36x RTFx on CPU (256 ms chunks, M5 Pro); v1.2 has 1.3M at 60x. The ANE is not used. "Not yet exercised inside production call pipelines." — [LocalVQE.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Enhancement/LocalVQE.md). The README cites ASR near-end word recall rising from 44.1% to 77.6% on a *synthetic* echo subset, which is an AEC scenario and not our case. — [FluidAudio README](https://github.com/FluidInference/FluidAudio)
- **DeepFilterNet3 Core ML ports:**
  - aufklarer: 2.1M parameters, 48 kHz, about 40 ms latency, iOS 17+.
  - iky1e streaming port: 10 ms hops, 30 ms delay.
  - Reported PESQ 3.10 / STOI 0.964 on VoiceBank-DEMAND. No WER data.

  — [aufklarer/DeepFilterNet3-CoreML](https://huggingface.co/aufklarer/DeepFilterNet3-CoreML), [iky1e/DeepFilterNet3-Streaming-CoreML](https://huggingface.co/iky1e/DeepFilterNet3-Streaming-CoreML), [soniqo guide](https://soniqo.audio/guides/denoise). An Apple Developer Forums post reports DeepFilterNet3 sometimes removes voice along with noise. — [Apple forums 829750](https://developer.apple.com/forums/thread/829750)
- **Codec effect (our 32 kbps AAC):**
  - GigaSpeech: Opus at 32 kbps raised WER by only 0.1–0.2% absolute (Kaldi system). — [GigaSpeech paper](https://arxiv.org/pdf/2106.06909)
  - Multi-channel Opus study: about 6.6% relative degradation at 32 kbps per channel, with sharp drops below 16 kbps. — [arXiv 2002.00122](https://arxiv.org/pdf/2002.00122)
  - A 2026 poster reportedly found no significant Whisper-large-v3 WER degradation from AAC, MP3 or Opus. Seen only via a search snippet, not verified. — [ISD 2026 poster](https://aisel.aisnet.org/isd2014/proceedings2026/datascience/13)

### Inferences
- 16 kHz mono AAC at 32 kbps is wideband and probably costs only a small amount of ASR accuracy. Far-field distance, reverb and overlapping talkers will dominate errors. Enhancement does not fix overlap and tends to add artifacts.
- Recommended: no enhancement in the ASR or diarization path. Optional `AUSoundIsolation` or LocalVQE on the audio *playback* path for user listening. If tested for ASR, A/B it on 1–2 h of labeled Bee audio before enabling.
- Simple, artifact-free preprocessing that is low-risk: DC removal and loudness normalization/AGC (Bee far-field levels may be low). These are our inferences, not benchmarked.

### Gaps
- No study of enhancement on far-field body-worn, low-bitrate audio with Parakeet specifically.
- No published WER impact for Apple `AUSoundIsolation`. Its on-device cost and whether it runs in offline manual-rendering mode in the background were not verified.
- No Whisper/Parakeet WER figure at exactly AAC-LC 32 kbps 16 kHz.

## 7. Recommended practical pipeline, expected throughput on A19 Pro, battery cost, background execution

### Takeaway
Recommended stack, one main dependency (FluidAudio, SPM):
- Decode AAC (AudioToolbox) and persist an Opus/AAC archive.
- Silero VAD (CPU) for live segmentation into utterances and conversations.
- Parakeet TDT v3/Ultra on the ANE for transcription, batched per conversation.
- pyannote community-1 offline diarization plus WeSpeaker embedding matching for "Me" and known contacts.
- Apple SpeechTranscriber as the fallback for unsupported languages.

Keep all ML on **CPU/ANE (never GPU)** for background viability. Run heavy passes (diarization and re-transcription) opportunistically while charging via `BGProcessingTask(requiresExternalPower)`. iPhone throughput is unmeasured. By inference from Mac numbers, it should be well above 20x real time, so a full day's speech (a few hours after VAD) likely needs on the order of 10–30 minutes of ANE time. This must be benchmarked on the actual device.

### Cited Findings
- **A19 Pro hardware:** 16-core Neural Engine, plus new "Neural Accelerators" inside each GPU core (reported as 3–4x peak GPU compute vs A18 Pro). The iPhone 17 Pro has 6 GPU cores. — [MacRumors](https://www.macrumors.com/2025/09/09/iphone-17-a19-chip/). Battery capacity is listed at about 15.5 Wh (3,988 mAh) for the physical-SIM model. — [Wikipedia: iPhone 17 Pro](https://en.wikipedia.org/wiki/IPhone_17_Pro) (secondary; seen via search snippet)
- **Background compute:**
  - Apple's `MLComputeUnits` guidance suggests restricting to CPU if the app may run in the background or alongside GPU-intensive work. — [Apple MLComputeUnits](https://developer.apple.com/documentation/coreml/mlcomputeunits) (via search summary)
  - Developer reports say background GPU access on iPhone is not available; it is iPad-only via entitlement or BGContinuedProcessingTask GPU resource. — [flowflow PR #201](https://github.com/mirkobozzetto/flowflow/pull/201) (anecdotal)
  - `BGContinuedProcessingTaskRequest.Resources` includes a `.gpu` option. — [Apple docs](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources)
- **ANE in background, iOS 27 risk:** An Apple Developer Forums post (June 2026) reports that "In iOS 26, Core ML reliably submits inference requests targeting the Neural Engine in the background" but that "in iOS 27 Seed 1, this capability is currently broken." Apple staff replied only that Core AI lets you express a Neural Engine preference "but it's up to Core AI." The background question was left unanswered. — [Apple forums 832048](https://developer.apple.com/forums/thread/832048)
- **Core AI (new at WWDC26):** Apple's "new framework for on-device AI model deployment" across CPU, GPU and Neural Engine. It has a Swift API, a `coreai-torch` converter, and a curated Core AI models repo; Core ML users will find it "pretty familiar." — [Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/), [Dive into Core AI](https://developer.apple.com/videos/play/wwdc2026/325/), [Integrate on-device AI models using Core AI](https://developer.apple.com/videos/play/wwdc2026/326/). FluidAudio and Argmax still ship Core ML `.mlmodelc` models (per their docs).
- **BGContinuedProcessingTask (iOS 26):** Must be submitted from the foreground "as a result of a person's action, such as tapping a button." It continues in the background with a system Live Activity progress UI that the user can cancel. The system may terminate it under resource constraints, prioritizing tasks with little progress, and it must report progress. — [BGContinuedProcessingTaskRequest](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest), [BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- **BGProcessingTaskRequest.requiresExternalPower** (iOS 13+): "specifying if the processing task requires a device connected to power." — [Apple docs](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresexternalpower)
- **Throughput anchors (Mac):**
  - Parakeet v3/Ultra about 150x (M5 Pro ANE, LibriSpeech) and about 335–457x on a 60-min file.
  - pyannote community-1 offline about 323x (M5 Pro).
  - Silero VAD about 1,000–1,400x.

  — [FluidAudio Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md). SpeakerKit Pro: 4 min of audio diarized in about 1 s on iPhone (about 240x, 2025 claim). — [Argmax SpeakerKit](https://www.argmaxinc.com/blog/speakerkit)
- **Model footprint (download/disk):**
  - Parakeet v3 encoder 445 MB (6-bit), Ultra 595 MB (int8), Redux 183 MB. — [ParakeetUltra.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)
  - CTC custom-vocabulary add-on 97.5 MB (about 130 MB peak). — [CustomVocabulary.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/CustomVocabulary.md)
  - Nemotron-3 diarizer 95–190 MB. — [Nemotron3.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Nemotron3.md)
  - SpeakerKit about 10 MB. — [Argmax](https://www.argmaxinc.com/blog/speakerkit)
  - whisper large-v3-turbo compressed about 954 MB. — [WhisperKit README](https://huggingface.co/argmaxinc/whisperkit-coreml/blob/20f51f218879660aa966596dfe336a762249abe8/README.md)
- **Cold start:** Parakeet v3 encoder load is 3.4 s cold and 0.16 s warm on iPhone 16 Pro Max, so keep the model resident during a processing batch. — [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)

### Inferences

**Comparison matrix** (iPhone figures are inferred unless noted):

| Option | Accuracy (reference) | Speed (reference) | Disk | Languages | License | Background-friendly | Swift effort |
|---|---|---|---|---|---|---|---|
| Apple SpeechTranscriber | 14.0% WER earnings22 (Argmax 2025) | 70x on M4 Mac | 0 (system asset) | about 10+ (verify on device) | Free, system | Unknown (undocumented) | Lowest: first-party async API |
| FluidAudio Parakeet v3/Ultra | 2.1–2.3% LS-clean; AMI 11.3%; E22 11.4% | about 150x M5 Pro ANE | 445–595 MB | 25 European | Apache-2.0 SDK; CC-BY-4.0 weights | Yes, ANE (FluidAudio claim; iOS 27 ANE-background report is a risk) | Low: SPM, async managers |
| WhisperKit large-v3-turbo (OSS) | 2.0–2.5% LS (HF table); best open long-form WER family | Several times slower than Parakeet | about 954 MB compressed | 99 | MIT | ANE possible | Low to medium |
| Argmax Pro (Parakeet + Sortformer) | 11.7% earnings22 (Parakeet v2) | 359x M4 | — | — | Commercial | Yes | Low; paid |
| whisper.cpp v1.9.5 | Whisper-equivalent | GPU/Metal-centric | — | 99 | MIT | Poor (GPU) | Medium (C API) |
| Moonshine v2 | "On par with 6x larger" | Fast, streaming | Tiny about 80 MB INT8 | English (Tiny) | Unclear | Unknown | Medium/high (no first-party Swift SDK verified) |

**Pipeline proposal:**
1. **Ingest (always on, background via bluetooth-central):** Decrypt, reassemble ADTS (drop the first 3 frames), decode AAC to 16 kHz Float32 with AudioToolbox/AVAudioConverter, and append the raw AAC to a rolling on-disk archive. Store compressed audio, not PCM: 32 kbps ≈ 14.4 MB/h, about 230 MB per 16-h day.
2. **Live VAD (CPU):** Silero via FluidAudio, producing utterance boundaries and conversation sessions (section 4 heuristics). Only speech segments are queued.
3. **ASR (ANE):** Parakeet Ultra/v3 on queued segments in small batches while the app is alive in the background, falling back to a deferred queue if ANE background submission fails. Use SpeechTranscriber for locales outside the 25 languages.
4. **Diarization and ID (ANE/CPU), per closed conversation:** pyannote community-1 offline, exclusive output. Compute cluster centroids, match to the wearer and known-contact gallery, then assign speakers to Parakeet word timestamps.
5. **Heavy or redo passes:** Re-transcription with custom vocabulary, re-diarization and summarization run in `BGProcessingTask` with `requiresExternalPower = true` overnight. A user-triggered `BGContinuedProcessingTask` handles "process now."

**Throughput and battery estimate (inference, must be measured):**
- A19 Pro ANE is unlikely to match an M5 Pro. Assume roughly 25–50% of Mac ANE throughput, giving Parakeet at about 40–75x and pyannote offline at about 80–160x on iPhone 17 Pro. The Nemotron iOS data point (CPU encoder about 66x) suggests the same order of magnitude.
- A wearable day with 16 h captured might contain 3–6 h of speech after VAD. At 40x, 5 h of speech is about 7.5 min of ASR compute, plus about 2–4 min of diarization.
- Throughput is roughly 40–75 hours of audio per hour of compute for ASR on speech-only segments.
- At an assumed 3–5 W package power during ANE inference (no source), 10–15 min of compute is about 0.5–1.25 Wh, or about 3–8% of a 15.5 Wh battery per day. BLE streaming, AAC decode and VAD add a continuous baseline cost (unmeasured), probably larger than the ML cost over 16 h.
- Doing the heavy passes on charger makes the ML battery impact near zero.

**Risks to validate on the real device:**
1. ANE inference while backgrounded on iOS 27.0.1 (the forum report of breakage in Seed 1). If broken, queue work for foreground or charging windows, or use CPU-only (slower but allowed).
2. Thermal throttling during long batches.
3. Core ML to Core AI migration: FluidAudio and Argmax are still Core ML. Monitor whether Apple deprecates Core ML.

### Gaps
- **No measured numbers for any of these models on A19 Pro / iPhone 17 Pro** (RTF, memory, energy). All iPhone throughput and battery figures above are inferences from Mac benchmarks and need on-device profiling (Instruments Power Profiler / Energy log).
- No authoritative Apple statement on ANE use from a backgrounded app in iOS 27 GA. Only one developer report of breakage in iOS 27 Seed 1.
- No published energy-per-audio-hour for Parakeet, Whisper or SpeechTranscriber on any iPhone.
- iOS background CPU limits for bluetooth-central apps doing sustained ML were not found in primary docs.
