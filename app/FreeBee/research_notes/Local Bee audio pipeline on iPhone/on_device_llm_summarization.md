# On-device LLM summarization, structured extraction and semantic search on iPhone 17 Pro (iOS 27)

Scope: what turns FreeBee's diarized transcripts into daily summaries, per-conversation summaries, action items, people and topics, "memories", and natural-language Q&A, with everything running on the phone. Research date: 2026-10-20. Project facts: the app's deployment target is already iOS 27.0 (`IPHONEOS_DEPLOYMENT_TARGET = 27.0` in project.pbxproj), so it can use iOS 27-only APIs without availability checks.

## 1. Apple Foundation Models framework (iOS 26, then iOS 27 / WWDC26): model, context window, APIs, limits, adapters, guardrails

### Takeaway
iOS 27 ships a third-generation on-device model (AFM 3). Secondary reporting says iPhone 17 Pro gets the larger "Core Advanced" tier, a 20B sparse model with 1–4B parameters active. The framework also gained token counting and usage APIs, image input, a pluggable `LanguageModel` protocol (MLX and Core AI models can sit behind the same `LanguageModelSession`), and a Spotlight RAG tool. The on-device context window is still small: Apple's WWDC26 sample shows `contextSize` = 8192, but an Apple engineer wrote "4K" in June 2026, so the app should read it at runtime. Two other limits matter: custom adapters are dead on iOS 27, and on-device inference is throttled in the background on battery.

### Cited Findings
**Model generations**
- 2025 on-device model (iOS 26): about 3B parameters, optimized with KV-cache sharing and 2-bit quantization-aware training. Block 2 (37.5% of layers) reuses Block 1's KV cache, which cuts KV memory by 37.5% and time-to-first-token by about 37.5% — [Apple Intelligence Foundation Language Models Tech Report 2025 (arXiv 2507.13575)](https://arxiv.org/abs/2507.13575); [Apple ML Research page](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025)
- Third generation announced June 8, 2026 (footnote updated September 9, 2026), "built in collaboration with Google". Tiers:
  - AFM 3 Core: a 3B dense on-device model.
  - AFM 3 Core Advanced: on-device, natively multimodal, 20B parameters in a sparse architecture, activating 1 to 4B per request, "unlocked by and optimized for" Apple's most capable silicon. It uses Instruction-Following Pruning: the full model sits in flash, routing is decided per prompt rather than per token, and routed experts are loaded into DRAM as needed.
  - Server tiers: AFM 3 Cloud and AFM 3 Cloud Pro (on NVIDIA GPUs in Google Cloud).

  — [Apple ML Research: Introducing the Third Generation of Apple's Foundation Models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- Human preference for AFM 3 Core vs the 2025 on-device baseline (general text): 45.6% vs 23.3%. Apple gives no context length, latency, or summarization-specific numbers, and promised a technical report "later this summer" — [Apple ML Research](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models)
- Device tiers (secondary, citing MacRumors on the iOS 27 beta): Core Advanced runs on iPhone Air, iPhone 17 Pro and 17 Pro Max. Core runs on iPhone 15 Pro and later Apple Intelligence devices. The article gives no API for choosing a tier and warns a session "may silently get routed" to the smaller model — [ChatForest iOS 27 builder guide](https://chatforest.com/builders-log/apple-foundation-models-ios-27-on-device-llm-api-builder-guide/). This is not confirmed in Apple docs.
- Apple Frameworks Engineer (June 2026): "Passing an image does not change the model servicing the request." Also: "There is currently no pinning or model version retrieval API… we recommend using the Evaluations framework to catch regressions." — [Apple Developer Forums 833642](https://developer.apple.com/forums/thread/833642)

**Context window (sources conflict)**
- iOS 26: 4,096 tokens, shared by instructions, prompt and output (about 3,000 English words) — [Kodeco Foundation Models book ch.4](https://www.kodeco.com/books/apple-foundation-models/v1.0/chapters/4-context-management-model-safety); [ChatForest](https://chatforest.com/builders-log/apple-foundation-models-ios-27-on-device-llm-api-builder-guide/)
- WWDC26 session 241 sample code: `SystemLanguageModel().contextSize` prints `8192`. `contextSize` and `tokenCount(for:)` arrived in iOS 26.4 — [WWDC26 "What's new in the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2026/241/); [DEV Community recap](https://dev.to/hariharanjagan/whats-new-in-apples-foundation-models-framework-at-wwdc-2026-5227)
- This conflicts with an Apple Frameworks Engineer in June 2026: "The on-device model has a 4K context window." The engineer suggests profiling with `response.usage`, compacting transcripts with Foundation Models Utilities / Dynamic Instructions, and "delegating sub-tasks to new sessions" — [Apple Developer Forums 833642](https://developer.apple.com/forums/thread/833642)
- Overflow throws `LanguageModelSession.GenerationError.exceededContextWindowSize` — [ChatForest](https://chatforest.com/builders-log/apple-foundation-models-ios-27-on-device-llm-api-builder-guide/)
- Private Cloud Compute model: 32,000-token context with reasoning levels (`.light`, `.deep`), free for developers under 2M first-time downloads. It runs off-device, so it is out of scope for FreeBee — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)

**New iOS 27 APIs relevant to FreeBee**
All from [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/):
- `response.usage`: input/cached/output/reasoning token counts.
- Image `Attachment`.
- Improved on-device tool calling.
- Built-in `BarcodeReaderTool` and `OCRTool`.
- A Spotlight-powered search tool for fully local RAG.
- `DynamicProfile`/`Profile`: switch instructions, tools and model per mode within one session.
- An Evaluations framework for measuring the quality impact of prompt changes.
- An `fm` CLI on macOS 27 and a Python SDK (`apple_fm_sdk`) exposing the same on-device model.
- An open-sourced core framework plus a utilities package (transcript management, skill API, Chat Completions-compatible model).
- New `LanguageModel` protocol: `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` conform, and Apple published open-source `CoreAILanguageModel` and `MLXLanguageModel` so local open models can back a `LanguageModelSession`.

From [Apple Developer Forums 833642](https://developer.apple.com/forums/thread/833642):
- Guided generation (`@Generable`) "broadly supports schemas as long as they can be represented in JSON". Smaller schemas are easier for the model, and an unsatisfiable schema raises an error.
- Tool arguments always follow the schema.

**Concurrency, rate limits and background**
- "The OS limits the amount of concurrent requests to the model… there might be a delay." Also: "On iOS, we might limit access to the model on background tasks… excessive requests to the model made in the background might be throttled or canceled." — Apple Frameworks Engineer, June 2026, [Forums 833642](https://developer.apple.com/forums/thread/833642)
- No entitlement or API can raise priority. "The OS manages the requests for the on-device LLM automatically, based on the system conditions (like thermals)" — Apple Frameworks Engineer, June 2026, [Forums 833666](https://developer.apple.com/forums/thread/833666)
- iOS 26-era answers:
  - "Rate limiting applies when your device is on battery AND when your process is running in the background." It is not expected on power.
  - Avoid streaming in the background, since it uses more power and hits the limit sooner.
  - Inference on the shared on-device model runs serially.
  - Foreground use is not limited unless the device is under heavy load.

  — [Forums 789788](https://developer.apple.com/forums/thread/789788); [WWDC25 Group Lab summary 791086](https://developer.apple.com/forums/thread/791086); [Forums 793787](https://developer.apple.com/forums/thread/793787)

**Guardrails**
- iOS 26.4 reduced false positives, and "we're continuing to make even more improvements in iOS 27" — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)
- Developers report false positives on summarization: political news, "generating a summary from a longer citation". Apple asks for Feedback Assistant reports — [Forums 787736](https://developer.apple.com/forums/thread/787736)
- Around iOS 26.5, prompts failed with guardrail violations even with `SystemLanguageModel(guardrails: .permissiveContentTransformations)`. The poster says that mode does not apply to `@Generable` output (developer report, unconfirmed) — [Forums 835777](https://developer.apple.com/forums/thread/835777)
- Apple's acceptable-use rules prohibit circumventing the framework's guardrails — [Acceptable use requirements](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework/)

**Adapters (custom fine-tuning)**
- From the [Apple adapter training toolkit page](https://developer.apple.com/apple-intelligence/foundation-models-adapter/):
  - "Version 26.0.0 is the last release of this toolkit and is not compatible with macOS, iOS, iPadOS, or visionOS 27 and later."
  - Each adapter is about 160 MB and tied to a single system-model version.
  - Shipping one requires the Foundation Models Framework Adapter Entitlement.
  - Training needs an Apple-silicon Mac with 32 GB or more, or a Linux GPU machine. Apple suggests 100–1,000 samples for basic tasks and 5,000+ for complex ones.
- iOS 27 has no bring-your-own fine-tuned weights for the system model; "that path is Core AI" — [DEV Community recap](https://dev.to/hariharanjagan/whats-new-in-apples-foundation-models-framework-at-wwdc-2026-5227)

### Inferences
- Read `SystemLanguageModel.default.contextSize` on the user's iPhone 17 Pro running iOS 27.0.1 and log it rather than hard-coding 4K or 8K. 8192 may be the Core Advanced value and 4096 the Core value, but no source confirms this. Use `tokenCount(for:)` to size chunks dynamically.
- Foundation Models fits short, schema-bound jobs on one conversation segment: action items, people, topics, a title, and a 3–5 sentence summary via `@Generable` structs persisted to SwiftData. It needs no model download, it is not GPU-bound, and on power it is the only LLM path Apple sanctions for background work.
- It is a poor fit for a single-pass daily summary over tens of thousands of tokens, which needs map-reduce (section 3).
- Guardrail refusals on private conversations (arguments, medical or political talk) are a real risk. Catch `guardrailViolation` and fall back to an open model through the same `LanguageModelSession` API via `MLXLanguageModel`. This keeps one prompt and schema codebase. Whether `@Generable` constrained decoding is fully supported by `MLXLanguageModel` is unverified.
- Model updates are silent with OS updates and cannot be pinned. Keep a small regression set of real Bee transcripts and score it with the Evaluations framework, or on the Mac with `apple_fm_sdk` or `fm`, after each iOS update. The Mac Python client (`mac/src/beekit/transcribe.py`) can produce that test set.
- Do not plan on adapters on iOS 27: the toolkit is end-of-life for 27.

### Gaps
- No Apple documentation found that states the iOS 27 on-device context size per tier, or how to tell which tier (Core vs Core Advanced) is serving requests.
- No published tokens/s or TTFT for AFM 3 on iPhone 17 Pro. One community benchmark has only a Mac figure: 85.2 tok/s decode, 269 ms TTFT ([apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)).
- No numeric background rate-limit budget is published.
- The iOS 27 language list was not retrieved. Apple's AFM 3 post evaluates four locale groups (English variants, PFIGSCJK, DDNSTV, AFIHHMPRTU) without naming developer-facing languages.
- No evidence was found of a public text-embedding API in Foundation Models (section 4).

## 2. Open models on iPhone 17 Pro via MLX Swift, llama.cpp, LiteRT-LM and Core AI: quality, speed, RAM, long context, battery and thermals

### Takeaway
The strongest current small open families are Qwen3.5 (0.8B, 2B, 4B, 9B; released March 2, 2026; 262K native context) and Gemma 4 (E2B and E4B; 128K context). On iPhone 17 Pro, 4-bit 2B-class models decode at about 47–61 tok/s on MLX Swift and prefill at about 3,300 tok/s. In practice the binding constraint is a roughly 6 GB per-app memory ceiling, not the 12 GB of physical RAM. Sustained GPU decoding loses 50–60% of its speed within minutes when the phone is unplugged.

### Cited Findings
**Hardware**
- iPhone 17 Pro and Air have 12 GB RAM, the base iPhone 17 has 8 GB. Apple has not officially confirmed this; it is backed by Geekbench data — [gori.me](https://gori.me/iphone/161530); [MacRumors A19 vs A19 Pro](https://www.macrumors.com/2025/09/09/iphone-17-a19-chip/)
- A19 Pro: 6-core GPU on 17 Pro, a "Neural Accelerator" in each GPU core with 4x the peak compute of A18 Pro, and a 16-core Neural Engine — [Wikipedia: Apple A19](https://en.wikipedia.org/wiki/Apple_A19); [Draw Things](https://releases.drawthings.ai/p/iphone-17-pro-doubles-ai-performance)
- Per-app memory ceiling of about 6,144 MB on a 12 GB iPhone 17 Pro Max, even with `com.apple.developer.kernel.increased-memory-limit` (about 6,656 MB with the debugging entitlement). In that test Gemma 4 multimodal in mlx-swift-lm loaded at about 4.4 GB and left about 1.7 GB for inference. Shrinking the MLX GPU buffer cache from 512 MB to 64 MB avoided jetsam. This is one developer's measurement with no Apple reply — [Forums 834805](https://developer.apple.com/forums/thread/834805)
- Apple: the increased memory limit is only available on some devices, and apps should check `os_proc_available_memory` — [Apple entitlement docs](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit.md)

**Measured speed and memory on iPhone 17 Pro**
- Qwen 3.5 2B, about 4-bit, iOS 26.4.2, 128-token short chat, Debug builds (2026-05-28/06-02) — [DEV Community, MLBoy](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42); [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)

  | Runtime | Decode tok/s | Peak memory |
  |---|---|---|
  | MLX Swift | 61.2 | 1,279 MB |
  | llama.cpp | 39.1 | 1,479 MB |
  | Core ML/ANE | 27.9 | 241 MB |

- Gemma 4 E2B on iOS 27.0, warm protocol — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)

  | Runtime and build | Decode tok/s | Memory | GSM8K |
  |---|---|---|---|
  | LiteRT-LM | 61.1 | 497 MB | 86% |
  | MLX Swift 4-bit PTQ | 49.1 | 3,010 MB | 84% |
  | Core AI int4 | 47.1 | 755 MB | 88% |
  | llama.cpp Q4_K_M | 38.8 | — | 76% |
  | MLX QAT OptiQ int4 | 36.0 | 4,592 MB | 91% |

  - Prefill at 1,024 prompt tokens: LiteRT-LM 3,513 tok/s, MLX 3,274 tok/s.
  - In an earlier run on iOS 26.4.2: LiteRT-LM 55.4 tok/s at 641 MB, MLX 47.5 tok/s at 2,900 MB ([DEV Community](https://dev.to/john-rocky/on-device-llm-on-iphone-which-runtime-is-fastest-mlx-vs-llamacpp-vs-litert-lm-vs-coreml-1b42)).
- Qwen3-0.6B 4-bit on MLX: 158.8–178.8 tok/s at 489 MB. Results vary a lot between sessions and iOS builds: "Cross-session ratios are invalid on this device" — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)
- Core AI (WWDC26's Core ML successor) LLM path: an iOS KV cap of 1,024 caused jetsam with a 2,048-token budget — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench). Core AI was announced at WWDC26 as Core ML's successor for on-device LLM and generative models — [InfoQ](https://infoq.com/news/2026/06/apple-core-ai-wwdc); [WWDC26 "Meet Core AI" (324)](https://developer.apple.com/videos/play/wwdc2026/324)

**Thermal and battery: Gemma 4 E2B, 600 s sustained, unplugged**
From [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench):
- MLX/GPU fell from 48 to 18 tok/s (38% retained) and crossed 50% loss within about 60 s.
- LiteRT-LM/GPU fell from 56 to 27 tok/s (48% retained).
- ANE (CoreML-LLM) fell from 33 to 22 tok/s (67% retained).
- On Mac, ANE draws about half the GPU path's package power.
- iPhone energy: LiteRT-LM 0.147 J/token, MLX Swift 0.182 J/token. Core AI's 0.352 J/token is a lower bound.

**Models**
- Qwen3.5 small models — [Gigazine](https://gigazine.net/gsc_news/en/20260303-qwen-3-5-small); [Artificial Analysis](https://artificialanalysis.ai/articles/qwen3-5-small-models); [InsiderLLM](https://insiderllm.com/guides/qwen-3-5-small-models-9b-beats-30b/)
  - Released March 2, 2026 in 0.8B, 2B, 4B and 9B sizes. Dense, Apache 2.0, natively multimodal, 262K-token native context.
  - Artificial Analysis rates the 4B as the strongest model under 5B and the 9B as the strongest under 10B.
  - A reviewer reports 80–82% hallucination rates on factual benchmarks and 2–4x more output tokens than peers. This is secondary and unverified.
- Qwen3.5-4B architecture (secondary listings) — [Modal](https://modal.com/library/qwen/qwen3-5-4b); [Azure/Fireworks](https://ai.azure.com/catalog/models/FW-Qwen3.5-4B); [HF model card](https://huggingface.co/Qwen/Qwen3.5-4B)
  - 32 layers, as 8 repeats of three Gated DeltaNet linear-attention layers plus one gated full-attention layer.
  - 262,144-token native context, extensible to about 1M with YaRN.
- Gemma 4: small models (E2B and E4B) have 128K context, medium models 256K — [Google Gemma docs](https://ai.google.dev/gemma/docs/core)
  - E2B has 5.1B total and 2.3B effective parameters.
  - E2B and E4B run in about 5 GB at 4-bit, or about 15 GB at 16-bit. Context adds more memory.

  — [Unsloth Gemma 4 guide](https://unsloth.ai/docs/models/gemma-4)
- Practical MLX Swift on iOS advice: keep usage under about 60% of RAM, cap the GPU cache (about 512 MB), call `Memory.clearCache()` after heavy phases, and test on device only, since the Simulator cannot exercise Metal inference — [community MLX Swift skill reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/apple-on-device-ai/references/mlx-swift.md)

### Inferences
- Recommended open-model tier for FreeBee:
  - **Qwen3.5-4B 4-bit on MLX Swift** for the daily rollup and Q&A synthesis. This is the best quality under 5B with long native context.
  - **Qwen3.5-2B 4-bit** (about 1.3 GB peak, about 61 tok/s) as the fast path.
  - **Gemma 4 E2B via LiteRT-LM** if energy or memory dominates: lowest J/token and about 0.5 GB. LiteRT-LM's Swift integration story was not researched.
- Qwen3.5's 3:1 linear-attention hybrid keeps full-attention KV for only 8 of 32 layers. That should make 16–32K-token prompts far more memory-affordable than in a pure-attention 4B model. This is an inference from the architecture and has not been measured on iPhone. With a roughly 6 GB ceiling and about 2.5–3 GB of 4-bit weights, 32K context looks plausible for Qwen3.5-4B and tight for Gemma 4 E2B on MLX, whose footprint is already about 3 GB.
- Prefill at about 3,300 tok/s means reading a 30K-token day takes roughly 10 s of compute before throttling. Decode is the expensive part, so keep outputs short and structured. Thermal throttling roughly halves GPU throughput after about a minute unplugged, so schedule big jobs while charging.
- Treat Llama 3.2 3B, Phi-4-mini, SmolLM3 and Gemma 3n as older options superseded by Qwen3.5 and Gemma 4 for this use. No 2026 iPhone 17 Pro numbers were found for them.
- `MLXLanguageModel` (section 1) lets the same `LanguageModelSession` code drive Apple's model or a Qwen or Gemma MLX model. That is the cleanest way to build a fallback chain.

### Gaps
- No iPhone 17 Pro measurements found for Qwen3.5-4B or Qwen3-4B decode speed, or for prefill and KV memory at 8K, 16K or 32K prompts in any runtime.
- No head-to-head summarization-quality benchmark (ROUGE, G-Eval, BooookScore) found comparing AFM 3, Qwen3.5 and Gemma 4 on conversational transcripts.
- Gemma 4's exact release date and official model card were not retrieved. Benchmarks show it running on iPhone by June 2, 2026.
- Whether App Store builds get more than about 6 GB with the increased-memory-limit entitlement on iPhone 17 Pro under iOS 27 is unknown. One thread reports App Store builds crashing around 6 GB ([Forums 770868](https://developer.apple.com/forums/thread/770868)).
- The A19 Pro "40% better sustained performance" claim seen in search snippets was not verified against a primary source.

## 3. Techniques for long transcripts within mobile limits: chunking, map-reduce and rolling summaries, structured extraction, evaluation

### Takeaway
Use a hierarchy. First, extract per segment, with one segment per VAD-bounded conversation chunk of about 1.5–3K tokens, into `@Generable` structs stored in SwiftData. Then merge the structured outputs, not the raw text, into conversation-level and daily summaries. The literature shows a trade-off: hierarchical merging is more coherent, while incremental rolling updates keep more detail and benefit from bigger chunks. Apple's own guidance for the small window is to split work into new sessions and compact transcripts.

### Cited Findings
- BooookScore (ICLR 2024) compared hierarchical merging of chunk summaries against incremental updating of a running summary. Incremental updating scores lower on BooookScore but gives a "higher level of detail", which annotators sometimes prefer. Bigger chunks "significantly improve incremental updating". BooookScore is the fraction of summary sentences free of identified error types and agrees well with humans — [BooookScore, arXiv 2310.00785](https://arxiv.org/pdf/2310.00785); [GitHub](https://github.com/lilakk/BooookScore)
- A 2025 long-document summarization study split inputs into 2,048-token chunks, summarized each with Llama-3.1-8B-Instruct, then merged hierarchically — [Hallucinate at the Last…, arXiv 2505.15291](https://arxiv.org/pdf/2505.15291)
- Apple's guidance for the on-device context limit: use `usage` to profile, compact transcripts with Dynamic Instructions and Foundation Models Utilities, and "consider delegating sub-tasks to new sessions" — [Forums 833642](https://developer.apple.com/forums/thread/833642). Overflow is signalled by `exceededContextWindowSize`, and the suggested recovery is a fresh or condensed session — [community skill reference](https://skillsmp.com/creators/foxtrottwist/swift-skills/skills-foundation-models)
- Guided generation guarantees schema-conformant output (JSON-representable schemas). Smaller schemas are easier for the model — [Forums 833642](https://developer.apple.com/forums/thread/833642)
- The iOS 27 Evaluations framework measures quality and the "statistical impact of prompt changes". The macOS 27 `fm` CLI and Python SDK run the same on-device model for offline evaluation — [WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/)

### Inferences
- A pipeline that fits a 4K–8K window:
  1. **Segment.** Use VAD, diarization and silence gaps longer than about 2 minutes to form "conversations". Split conversations into chunks of about 1.5–3K tokens at speaker-turn boundaries, sized with `tokenCount(for:)` and leaving room for instructions and output.
  2. **Map: per chunk, one fresh session.** `@Generable struct ChunkExtract { summary: String (2–4 sentences); actionItems: [ActionItem{text, owner?, due?}]; people: [String]; topics: [String]; decisions: [String]; quotes/memories: [String] }`. Keep schemas small, and split into two calls if quality drops.
  3. **Reduce: per conversation.** Merge the ChunkExtract JSONs, which are far smaller than the raw text, into a ConversationSummary. Deduplicate action items and people against SwiftData entities. Fold in a rolling summary when a conversation outgrows one reduce pass.
  4. **Daily.** Reduce the conversation summaries into a DailySummary of highlights, open to-dos and "memories". This tier is where the 32K-context open model (Qwen3.5-4B) pays off, because it can read all conversation summaries, plus selected raw excerpts, in one pass.
  5. **Incremental.** Run the map step soon after each conversation ends; the work is small and fits Foundation Models. Run reduce and daily passes while charging.
- Store raw transcript chunks (with speaker, timestamps and a conversation ID) and every extract in SwiftData. Keep provenance, a chunk ID for each action item or quote, so the UI can link to the original audio and transcript. This also helps catch hallucinations.
- Evaluation plan:
  - Build a gold set of 20–50 real Bee conversations, captured with the Mac client, with hand-written action items and people.
  - Score extraction precision and recall (action items, people) and summary faithfulness with a BooookScore-style error taxonomy or LLM-as-judge on the Mac.
  - Re-run after every iOS update, since the model cannot be pinned, and whenever prompts change. Use the Evaluations framework, or `apple_fm_sdk` from the existing Python tooling.

### Gaps
- No studies were found that evaluate map-reduce versus rolling summarization specifically on noisy ASR conversation transcripts with sub-5B on-device models.
- No published guidance was found on optimal chunk sizes for AFM 3. The recommendation above is an engineering inference.

## 4. On-device embeddings and semantic search / RAG ("what did Sam say about X last week?")

### Takeaway
Apple's NaturalLanguage contextual embeddings are a weak retrieval model: about 512 dimensions, 256 tokens, per-token vectors, and Apple itself points to other APIs for similarity. Use EmbeddingGemma-300m (MRL down to 256 or 128 dimensions, under 200 MB quantized, 100+ languages) or a similar small retriever. Store vectors in SQLite with sqlite-vec next to FTS5 BM25, run hybrid retrieval with structured filters for speaker and date, then answer with Foundation Models within the context window. Apple's iOS 27 alternative is Core Spotlight's semantic index plus the new Spotlight search tool for Foundation Models.

### Cited Findings
- `NLContextualEmbedding`: iOS 17+ — [Apple docs](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding.md)
  - 512-dimensional vectors with up to 256 tokens per request. It returns a vector per token, so it needs pooling. There are three underlying models by language — [Callstack](https://callstack.com/blog/on-device-ai-introducing-apple-embeddings-in-react-native)
  - Vectors are 512-dimensional on iOS and 768 on macOS — [NaturalLanguageEmbeddings package](https://swiftpackageregistry.com/buh/NaturalLanguageEmbeddings)
  - Apple's docs suggest `NLEmbedding` for semantic similarity tasks; `NLContextualEmbedding` is aimed at classifiers and taggers — [search summary of Apple docs](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding.md)
- EmbeddingGemma-300m — [Hugging Face blog](https://huggingface.co/blog/embeddinggemma); [Google Developers Blog](https://developers.googleblog.com/introducing-embeddinggemma/)
  - 308M parameters (about 100M model, 200M embedding), 768 dimensions with Matryoshka truncation to 512, 256 or 128, and a 2K-token context.
  - Under 200 MB RAM when quantized and 100+ languages. At release it was the top text-only multilingual embedding model under 500M on MMTEB.
  - Prompt prefixes: query `task: search result | query: `, document `title: none | text: `.
  - MIRIAD NDCG@10:

    | Model | NDCG@10 |
    |---|---|
    | EmbeddingGemma base | 0.8340 |
    | Qwen3-Embedding-0.6B | 0.8493 |
    | bge-base-en-v1.5 | 0.7541 |

  - Listed runtimes include Transformers.js and ONNX Runtime. MLX, llama.cpp and Core ML are not mentioned in the blog.
- sqlite-vec — [sqlite-vec GitHub](https://github.com/asg017/sqlite-vec)
  - `vec0` virtual tables hold float, int8 or binary vectors, with KNN via `MATCH … ORDER BY distance LIMIT k`.
  - Metadata, auxiliary and partition-key columns are supported, which suits speaker, date and conversation-ID filters.
  - Mozilla Builders project, "pre-v1, so expect breaking changes!" iOS is not listed among official targets.
- SQLiteVecKit bundles sqlite-vec with BM25 lexical and hybrid search for iOS and macOS, maturity unverified — [Swift Package Index](https://swiftpackageindex.com/carlosypunto/SQLiteVecKit). VecturaKit is an alternative Swift vector DB with an NLContextualEmbedding option, iOS 17+ — [VecturaKit](https://www.sourcepulse.org/projects/27414651)
- iOS 27 Apple-native RAG: WWDC26 session 246 "LLM search using Core Spotlight" builds RAG on `SpotlightSearchTool` with `LanguageModelSession`. The model writes its own queries against the app's Core Spotlight semantic index and reasons over the results. It depends on donated content and metadata quality — [WWDC26 session 246](https://developer.apple.com/wwdc26/246/); [WWDC Notes](https://wwdcnotes.com/documentation/wwdc26-246-llm-search-using-core-spotlight/); [Blake Crosley](https://blakecrosley.com/blog/on-device-ai-spotlight-media-ios-27)

### Inferences
- Steps for "What did Sam say about X last week?":
  1. A Foundation Models `@Generable` query parser turns the question into `{speaker: "Sam", dateRange: lastWeek, topicQuery: "X"}`.
  2. SQL pre-filters on speaker and date via sqlite-vec partition or metadata columns.
  3. Hybrid retrieval: FTS5 BM25 plus vector KNN, fused with reciprocal rank fusion.
  4. Pack the top 5–10 utterance windows with timestamps into about 3K tokens.
  5. Foundation Models answers with citations back to chunk IDs and audio offsets.
- Implement both the custom path (sqlite-vec plus EmbeddingGemma) and Core Spotlight donation. Core Spotlight gives a system-native semantic index with zero model shipping, and `SpotlightSearchTool` agentic search, but less control over ranking and filters. The custom path is deterministic and testable.
- Scale is small: about 300 utterance-window chunks per day comes to roughly 110K chunks per year. At 256-dimension float32 that is about 110 MB a year; at int8 or binary, a few to about 30 MB. Brute-force KNN in sqlite-vec is enough, and ANN (USearch, DiskANN) is unnecessary for years of data.
- Keep embeddings in a separate SQLite file next to the SwiftData store, since SwiftData has no vector index, keyed by the SwiftData chunk UUID.
- EmbeddingGemma's 2K context covers utterance windows easily. NLContextualEmbedding's 256-token limit and lack of retrieval training make it a fallback only.

### Gaps
- No iPhone latency or throughput numbers found for EmbeddingGemma, bge-small or all-MiniLM via Core ML, MLX or ONNX. No official Core ML or MLX EmbeddingGemma build was confirmed.
- No evidence found of a Foundation Models embeddings API in iOS 26 or 27. The Core Spotlight semantic index internals (embedding model, dimensions) are not documented in the sources found.
- USearch on iOS was not researched.

## 5. Background execution and realistic daily compute budget

### Takeaway
Only Apple's Foundation Models is reliably usable in the background, and it is throttled when the phone is on battery and backgrounded. Apple says rate limiting is "not expected" on power. GPU runtimes (MLX, llama.cpp, LiteRT-LM GPU) should be assumed unavailable in the background on iPhone: `BGContinuedProcessingTask` GPU access reported false on iPhones under iOS 26, and backgrounding mid-Metal-work can crash the app. Design the day as cheap per-conversation extraction close to real time (Foundation Models, foreground or BLE-background) plus a heavy nightly rollup while charging. The compute for a day of speech is minutes, not hours.

### Cited Findings
- `BGContinuedProcessingTask` (iOS 26) can request background GPU "on supported devices" via entitlement `com.apple.developer.background-tasks.continued-processing.gpu`. However, `BGTaskScheduler.shared.supportedResources.contains(.gpu)` returned false on iPhone 15 Pro and 16 Pro, and no Apple reply clarifies whether any iPhone qualifies. Developers work around it by setting `isIdleTimerDisabled = true` and pausing when backgrounded — [Forums 816774](https://developer.apple.com/forums/thread/816774)
- whisper.cpp on iOS 26.2: backgrounding while GPU work is in flight revokes the work and crashes the app via a ggml/Metal abort. Before iOS 26 the job was simply terminated — [whisper.cpp issue 3531](https://github.com/ggml-org/whisper.cpp/issues/3531)
- A CLIP workload on `.cpuAndNeuralEngine` ran 4–5x slower in a `BGContinuedProcessingTask` in the background than in the foreground (unanswered) — [Forums 807957](https://developer.apple.com/forums/thread/807957)
- Continued-processing tasks can be terminated under resource pressure; tasks reporting minimal progress go first — [community background-processing reference](https://tessl.io/registry/dpearson2699/swift-ios-skills/3.9.0/files/skills/background-processing/SKILL.md)
- Foundation Models background limits (section 1):
  - Throttled only when on battery and in the background; "not expected when your device is connected to power" — [Forums 789788](https://developer.apple.com/forums/thread/789788)
  - iOS 27 guidance: background requests "might be throttled or canceled", with no priority entitlement — [Forums 833642](https://developer.apple.com/forums/thread/833642); [833666](https://developer.apple.com/forums/thread/833666)
- Energy and throughput anchors on iPhone 17 Pro — [apple-silicon-llm-bench](https://github.com/john-rocky/apple-silicon-llm-bench)
  - About 0.15–0.18 J per decoded token (LiteRT-LM, MLX).
  - About 3,300–3,500 tok/s prefill at 1K prompt (Gemma 4 E2B).
  - GPU decode drops to about 38–48% of burst after 10 minutes unplugged.

### Inferences
- Budget sketch. Assumptions, not sourced: about 4 hours of detected speech per day, about 150 spoken words per minute, about 1.3 tokens per word.
  - That gives about 47K transcript tokens per day.
  - **Map pass:** about 20 chunks of 2.5K tokens with about 250 output tokens each. Prefill is about 15 s total at 3K tok/s. Decode is about 5K tokens at about 25–50 tok/s, so 2–4 minutes allowing for throttling.
  - **Reduce and daily pass:** about 3–4K output tokens, 1–2 more minutes.
  - **Energy:** about 9K decoded tokens × 0.18 J ≈ 1.6 kJ, plus prefill. That is roughly 3% of a battery of about 15 Wh (about 54 kJ; capacity assumed, not verified). This is small next to continuous BLE streaming plus ASR. ASR, not summarization, is likely the larger daily compute cost (covered by other research tracks).
- Scheduling:
  - **Near real time, after each conversation ends.** Run Foundation Models extraction while the app is alive via the `bluetooth-central` background mode (already implemented). Use non-streaming `respond`, catch `rateLimited`, and queue for later. Throttling on battery is likely, so the queue must persist in SwiftData.
  - **Nightly while charging.** Submit a `BGProcessingTaskRequest` with `requiresExternalPower = true` (standard BackgroundTasks API, not re-verified this session) for Foundation Models reduce and daily passes, embeddings (on CPU or ANE if possible), and index maintenance. Foundation Models should not be rate-limited on power.
  - **MLX or other GPU models** (long-context daily rollup, guardrail fallback). Run them in the foreground. Options: a "Process today" button, or a "charging and app open" mode with `isIdleTimerDisabled`, for example in StandBy. Make the work checkpointed and resumable so a background transition cannot crash it mid-Metal-command.
  - On the device, check `BGTaskScheduler.shared.supportedResources.contains(.gpu)` under iOS 27.0.1 before ruling out `BGContinuedProcessingTask` with GPU on iPhone 17 Pro.
- Prefer ANE or Core ML paths for embeddings in the background. They avoid the Metal background restriction, though one report shows a 4–5x background slowdown.

### Gaps
- No source confirms whether iOS 27 or iPhone 17 Pro adds background GPU support for `BGContinuedProcessingTask`.
- No published numeric budget for Foundation Models background usage.
- No measured end-to-end daily energy figures for an always-on wearable transcription plus summarization pipeline on iPhone.
- `BGProcessingTask` runtime limits under iOS 27 were not researched in this session.
