# Dependencies

Verified against source on 2026-10-23. Paths are relative to the FluidAudio checkout at tag `v0.17.7`. **INFERRED** marks a conclusion drawn from reading code, as opposed to a signature or constant read directly from it.

## Pin

```swift
// swift-tools-version: 6.2   // needed: `.macOS(.v26)` only exists in PackageDescription 6.2
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
// target dependency: .product(name: "FluidAudio", package: "FluidAudio")
```

- `Package.swift` (tools 6.0) and `Package@swift-6.2.swift`: platform minimum is `.macOS(.v14)`. There are no external package dependencies and no `unsafeFlags`. C targets are `FastClusterWrapper` and `MachTaskSelfWrapper`, built with `cxxLanguageStandard: .cxx17`.
- There is one binary target, `NemoTextProcessing.xcframework` (about 8 MB per slice, used for TTS and ITN text normalization). We do not need it. With a 6.2 manifest you can opt out with `.package(url: ..., exact: "0.17.7", traits: [])`. After that, `TextNormalizer` passes text through unchanged.
- The library is built in Swift 6 mode. Our targets in Swift 5 mode can depend on it (INFERRED; see the Build check section).
- The `fluidaudiocli` executable ships in the same package. It is not linked unless we depend on it.

### WhisperKit: dropped

WhisperKit is dropped: Tanner decided the app uses Parakeet only, partly because Whisper invents words on near-silent tracks (see SPEC). For the record, here is what was found before the drop. `argmaxinc/WhisperKit` now resolves to `argmax-oss-swift`: tag `v1.1.1` is the same commit (1bbc57c) in both. Its products are `WhisperKit`, `SpeakerKit` and `TTSKit`, with a minimum of macOS 13 and no swift-transformers dependency (the Hub client is vendored in `ArgmaxCore`). Its `Package@swift-6.2.swift` puts `.unsafeFlags(["-enable-library-evolution", ...])` on its library targets. Do not re-add it without checking that it still builds as a versioned dependency. Both libraries define a type named `WordTiming`, so module-qualify that type if the two ever coexist.

## Shared conventions

- **Audio:** 16 kHz mono Float32 in [-1, 1] (`Shared/ASRConstants.swift`: `sampleRate = 16_000`). Convert with `AudioConverter().resampleBuffer(_ AVAudioPCMBuffer) -> [Float]` or `.resampleAudioFile(_ URL) -> [Float]` (`Shared/AudioConverter.swift`). Streaming `appendAudio(AVAudioPCMBuffer)` APIs resample internally, so you can feed them tap or engine buffers in any format.
- **Model storage:** `~/Library/Application Support/FluidAudio/Models/<repo folder>/` (`Shared/MLModelConfigurationUtils.swift`, `defaultModelsDirectory(for:)`). Downloads come from HuggingFace. `HF_TOKEN`, `https_proxy` and `REGISTRY_URL`/`MODEL_REGISTRY_URL` are read from the environment (`Shared/Download/HFClient.swift`, `ModelRegistry.swift`). Every loader below also takes an explicit directory.
- **Apple Silicon only:** `AsrModels.isModelValid` throws `unsupportedPlatform` on Intel.

## 1. Batch Parakeet (TDT)

Files: `ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift`, `.../TDT/AsrModels.swift`, `ASR/Parakeet/AsrTypes.swift`

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)   // or .v2 for English-only, .ultra (doc says better than v3)
// full signature: downloadAndLoad(to: URL? = nil, configuration: MLModelConfiguration? = nil,
//   version: AsrModelVersion = .v3, encoderPrecision: ParakeetEncoderPrecision = .int8,
//   encoderComputeUnits: MLComputeUnits? = nil, progressHandler: ProgressHandler? = nil) async throws -> AsrModels
let asr = AsrManager(config: .default)          // public actor AsrManager; init(config: ASRConfig = .default, models: AsrModels? = nil)
try await asr.loadModels(models)
var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
let r: ASRResult = try await asr.transcribe(samples, decoderState: &state, language: nil)  // samples: [Float] @16k
let words: [WordTiming] = buildWordTimings(from: r.tokenTimings ?? [])  // free function in AsrTypes.swift
```

- Other overloads: `transcribe(_ AVAudioPCMBuffer, decoderState:language:)`, `transcribe(_ URL, decoderState:language:)` and `transcribeDiskBacked(_ URL, ...)`. The URL overload memory-maps the file when it estimates more than `streamingThreshold` samples (480_000 by default, which is 30 s).
- **Gotcha:** the README and `Documentation/ASR/GettingStarted.md` show `asrManager.configure(models:)` and `transcribe(samples, source: .system)`. Neither exists in v0.17.7. Use `loadModels(_:)` and the `decoderState:` overloads instead.
- `ASRResult` (`Codable, Sendable`): `text`, `confidence: Float`, `duration`, `processingTime`, `tokenTimings: [TokenTiming]?` and `rtfx`.
- `TokenTiming`: `token`, `tokenId`, `startTime`, `endTime` (TimeInterval, in seconds) and `confidence`.
- `WordTiming`: `word`, `startTime` and `endTime`. Words are grouped on the `▁` and leading-space boundaries.
- Minimum input length is 0.3 s (`ASRConstants.minimumAudioDurationSeconds`); `transcribeDiskBacked` throws `ASRError.invalidAudioData` below it. Gate dictation clips under 0.3 s yourself.
- The encoder window is 15 s (`maxModelSamples = 240_000`). Longer audio is chunked internally: 11 s chunks with 2 s left and 2 s right context, decoded `ASRConfig.parallelChunkConcurrency = 4` at a time.
- `ASRConfig.init(sampleRate: 16000, tdtConfig: .default, ..., parallelChunkConcurrency: 4, streamingEnabled: true, streamingThreshold: 480_000, ...)`. The `transcriptionProgressStream` emits progress only for input longer than 15 s.
- `reset()` and `cleanup()` exist. Create a fresh `TdtDecoderState` for each independent clip.
- Model repos: v3 is `FluidInference/parakeet-tdt-0.6b-v3-coreml` (folder `parakeet-tdt-0.6b-v3-coreml`) and v2 is `FluidInference/parakeet-tdt-0.6b-v2-coreml` (`ModelNames.swift`, `Repo`). For offline use: `AsrModels.load(from: dir, version:)`, `AsrModels.modelsExist(at:version:)` and `AsrModels.defaultCacheDirectory(for:)`.
- **Threading:** `AsrManager` is an actor. One call runs at a time per instance. Calls are `async` and run off the main actor.

## 2. Streaming Parakeet

There are three engines. The protocol `StreamingAsrManager: Actor` (`ASR/Parakeet/Streaming/StreamingAsrManager.swift`) is implemented by EOU, Nemotron and Unified. `SlidingWindowAsrManager` does **not** implement it.

| Engine | Type | Model | Latency | Partial/final semantics |
|---|---|---|---|---|
| **Parakeet Unified 0.6B (recommended)** | `StreamingUnifiedAsrManager` | `FluidInference/parakeet-unified-en-0.6b-coreml` (English) | 320/640/1120/2080 ms | Greedy RNNT; emitted text is append-only (final) unless vocab boosting rewrites a tail |
| Sliding-window TDT v3 | `SlidingWindowAsrManager` | same as batch v3 | ~1–2 s hypothesis, 11 s confirm | Two tiers: `volatileTranscript` / `confirmedTranscript` |
| Parakeet EOU 120M | `StreamingEouAsrManager` | `parakeet-realtime-eou-120m-coreml/{160,320,1280}ms` | 160–1280 ms | Partial + end-of-utterance callback; lower accuracy (README: English only) |

`Documentation/ASR/GettingStarted.md` still names EOU as the streaming option. The Unified model is newer. Its doc comment says the streamed output "matches offline quality", and the README showcase lists a dictation app (Wisp) built on it.

### 2a. StreamingUnifiedAsrManager (`ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift`, `UnifiedConfig.swift`)

```swift
let live = StreamingUnifiedAsrManager(
    configuration: nil,                                   // MLModelConfiguration?
    config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7),  // 1120 ms tier
    encoderPrecision: .int8)                              // .fp16 also available
try await live.loadModels(to: nil, configuration: nil, progressHandler: nil)  // downloads if needed
// or: try await live.loadModels(from: dirContainingBundles)
await live.setPartialTranscriptCallback { text in ... }   // @Sendable (String) -> Void, full current transcript
try await live.appendAudio(pcmBuffer)                     // any format; resampled to 16 k
try await live.processBufferedAudio()                     // decode all complete windows
let words = await live.consumeWordTimings()               // drains; or consumeTokenTimings()
let text  = try await live.finish()                       // flush the tail (isFinal) and return the full transcript
try await live.reset()                                    // new session, models stay loaded
await live.cleanup()                                      // unload
```

- **Tiers.** Units are encoder frames, 80 ms = 1280 samples each. The tiers come from `StreamingModelVariant.unifiedConfig` in `ASR/Parakeet/Streaming/ParakeetModelVariant.swift`. Pass the frame triple exactly; each tier is a separate encoder bundle with the attention mask baked in.

  | Tier | `[left, chunk, right]` frames | Notes |
  |---|---|---|
  | 2080 ms | `[70,13,13]` | Default |
  | 1120 ms | `[70,7,7]` | Doc: lower latency and better WER than 2080 ms |
  | 320 ms | `[70,2,2]` | |
  | 640 ms | `[70,7,1]` | Same WER as 320 ms at ~2.5x RTFx |

  The encoder file is named `parakeet_unified_encoder_streaming_<L>_<C>_<R>[_int8].mlmodelc` (`ModelNames.ParakeetUnified`). `loadModels(to:)` downloads only the tier you configured.
- **Chunking.** You can append any number of samples. `processBufferedAudio()` runs every complete `[left|chunk|right]` window and trims old audio, so memory stays bounded and the engine is meant for hours-long streams. Call it after each append, or on a timer.
- **Partial vs final.** The text is built incrementally per chunk, so there is no volatile tier. `getPartialTranscript()` and the callback return the whole running transcript. Only after `configureVocabularyBoosting(...)` can earlier text change: it is rescored about every 15 s. Timings are global seconds from stream start. `consumeTokenTimings()` drains its buffer, and the last token in each batch has a provisional one-frame `endTime`.
- **Reset.** `reset()` clears samples, the windower, tokens, timings and RNNT state. One instance can be reused across sessions (`reset` then append again).
- The callback fires inside the actor during `processBufferedAudio`. Hop to `@MainActor` before touching UI.
- **Gotcha:** an int8 encoder with `computeUnits == .all` is forced to `.cpuAndNeuralEngine`, because CoreML GPU routing of int8 crashes in MPSGraph. On A16 the int8 encoder can fail to load; use `.fp16` there (issue #828). This does not apply to Macs (INFERRED).

### 2b. SlidingWindowAsrManager (`ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift`)

```swift
let sw = SlidingWindowAsrManager(config: .streaming)   // chunk 11 s, hypothesis 1 s, left 2, right 2, confirm 0.80
try await sw.loadModels(models)                        // reuse AsrModels (any version); loadModels(to:) downloads v3 only
try await sw.startStreaming(source: .microphone)
Task { for await u in await sw.transcriptionUpdates { u.text; u.isConfirmed; u.tokenTimings } }
await sw.streamAudio(pcmBuffer)
let final = try await sw.finish()
```

- **Gotcha (INFERRED from code):** the input `AsyncStream` is created once in `init`, and `finish()` and `cancel()` close it for good. `reset()` does not recreate it. **Use a new `SlidingWindowAsrManager` for each session** if you choose this engine.
- `left + chunk + right` must be 15 s or less, or `startStreaming` throws `invalidConfiguration`.

### Two concurrent instances (dictation and meeting)

- No streaming or batch manager uses a static or shared model cache. Each instance loads its own `MLModel`s and is its own actor, so a dictation `AsrManager` and the meeting `AsrManager` do not block each other at the Swift level. This is what the SPEC requires ("its own instance").
- Cost: each instance holds a full copy of the model in memory (the v3 download is about 480 MB, per `Documentation/ASR/GettingStarted.md`). Contention on the Neural Engine is possible. Both points are INFERRED; nothing in the source measures them.
- A single `AsrModels` value (`Sendable`) can be passed to two managers. Whether concurrent `MLModel.prediction` calls on shared models are safe is not documented by FluidAudio. Load separately to be safe (INFERRED).
- `SlidingWindowAsrSession` (`SlidingWindowAsrSession.swift`) shares one loaded model set across several streams keyed by `AudioSource` (`.microphone` / `.system`).

## 3. Diarization

### 3a. Offline: OfflineDiarizerManager (pyannote community-1 + VBx)

Files: `Diarizer/Offline/Core/OfflineDiarizerManager.swift`, `OfflineDiarizerTypes.swift`, `OfflineDiarizerModels.swift`, `Diarizer/Core/DiarizerTypes.swift`

```swift
var cfg = OfflineDiarizerConfig()            // .default; nested: segmentation, embedding, clustering, vbx, postProcessing
cfg.clustering.numSpeakers = nil             // or minSpeakers / maxSpeakers (Int?)
let dia = OfflineDiarizerManager(config: cfg)   // @available(macOS 14) public final class (NOT an actor)
try await dia.prepareModels(directory: nil, configuration: nil)   // download + compile
let res: DiarizationResult = try await dia.process(audio: samples16k) // or dia.process(url) (memory-mapped)
for s in res.segments { s.speakerId /*String*/; s.startTimeSeconds; s.endTimeSeconds /*Float*/; s.embedding; s.qualityScore }
res.speakerDatabase   // [String: [Float]]? per-speaker centroid embeddings
```

- Every `process` overload takes an optional progress callback, `@Sendable (Int, Int) -> Void`, reporting chunks done and total chunks. It runs on an unspecified executor.
- Model repo: `FluidInference/speaker-diarization-coreml`, pinned to revision `df2625ac…`, with variant `"offline"`. The required files are `Segmentation`, `FBank`, `Embedding`, `PldaRho` (`.mlmodelc`) and `plda-parameters.json` (`ModelNames.OfflineDiarizer`). These are 256-d WeSpeaker embeddings, which are not interchangeable with CAM++.
- **Default settings** (`OfflineDiarizerTypes.swift`):
  - segmentation: 10 s windows at 16 kHz;
  - embedding: `batchSize` 32, `excludeOverlap: true`, `minSegmentDurationSeconds` 1.0;
  - clustering: threshold 0.6, Fa 0.07, Fb 0.8, `constrainedAssignment: true`;
  - VBx: 20 iterations;
  - post-processing: `minGapDurationSeconds` 0.1, `exclusiveSegments: true` (no overlapping output segments).
- For short turns the docs recommend a smaller `segmentation.stepRatio`, for example 0.1 on fast exchanges (`Documentation/Diarization/GettingStarted.md`). The doc also says `warmStartFa/Fb` change the cluster count, not the turn alternation.
- Threading: the models are `nonisolated(unsafe)` and written only in `initialize`/`prepareModels`. Do not call `prepareModels` while a `process` call is running. Use one manager per concurrent job (INFERRED).
- A macOS 14 BNNS crash is documented. It is fixed in macOS 15 and later, so it does not affect us.

### 3b. Streaming or frame-based: `Diarizer` protocol (`Diarizer/DiarizerProtocol.swift`)

`LSEENDDiarizer` and `SortformerDiarizer` are both `final class`. Sortformer guards its state with an `NSLock`; LS-EEND has no lock, so serialize calls to it yourself.

```swift
let d = LSEENDDiarizer()   // Diarizer/LS-EEND/LSEENDDiarizer.swift
try await d.initialize(variant: .ami, stepSize: .step100ms, cacheDirectory: nil, computeUnits: .cpuOnly)
try d.addAudio(samples, sourceSampleRate: 16000)          // resamples (LS-EEND runs at 8 kHz)
if let u = try d.process() { u.finalizedSegments; u.tentativeSegments }   // [DiarizerSegment]
try d.finalizeSession()
// offline on the same engine:
let tl: DiarizerTimeline = try d.processComplete(samples, sourceSampleRate: 16000,
        keepingEnrolledSpeakers: nil, finalizeOnCompletion: true, progressCallback: nil)
d.reset(); d.cleanup()
```

- `DiarizerSegment` (`Diarizer/DiarizerTimeline.swift`): `speakerIndex: Int`, `startTime`, `endTime` and `duration` (Float seconds), `isFinalized` and `speakerLabel`. `DiarizerTimeline.speakers` is `[Int: DiarizerSpeaker]`, and each speaker has `finalizedSegments` and `tentativeSegments`.
- **LS-EEND** (README default for online use):
  - variants `.ami`, `.callhome`, `.dihard2` and `.dihard3` (`ModelNames.LSEEND.Variant`);
  - up to 10 speakers, 100 ms frames, about 900 ms tentative;
  - fastest on CPU;
  - per `Documentation/Diarization/LS-EEND.md`: more prone to false alarms, and speaker identity is local to the recording.
- **Sortformer**:
  - `SortformerDiarizer(config: .default, timelineConfig: .sortformerDefault)`; load with `SortformerModels.loadFromHuggingFace(config:cacheDirectory:computeUnits:)` and then `initialize(models:)`;
  - at most 4 speakers, 80 ms frames, the most stable identities;
  - misses quiet speech;
  - repo `FluidInference/diar-streaming-sortformer-coreml`; NVIDIA Open Model License.
- Both support `enrollSpeaker(withAudio:sourceSampleRate:named:...)`. The docs say Sortformer enrollment is the reliable one.
- `DiarizerManager` (`Diarizer/Core/DiarizerManager.swift`) is the legacy pyannote 3.1 online pipeline. The docs rank it last, so do not use it.

**Recommendation for the post-call pipeline:** run `OfflineDiarizerManager` per track. For the live view, LS-EEND (`.ami`) or Sortformer, if a live speaker split is ever needed.

## 4. Speaker embeddings: CAM++

Files: `Speaker/CampPlusEmbedder.swift`, `Speaker/CampPlusModels.swift`. The source marks this model as **beta**.

```swift
let emb = try await CampPlusEmbedder.load()            // public actor; downloads FluidInference/campplus-coreml
// or: CampPlusEmbedder(models: try CampPlusModels.load(from: dir))
let v: [Float] = try await emb.embed(audio: span16k)   // 192-d, L2-normalized (CampPlusEmbedder.embeddingDim = 192)
let sim: Float = CampPlusEmbedder.cosine(a, b)         // nonisolated static; plain dot product, assumes normalized input
```

- Input is 16 kHz mono in [-1, 1]. It is scaled internally by 32768 to the Kaldi int16 range. There is also `embed(audioURL:)`.
- The time dimension is dynamic, so any span length works and nothing is padded. The source sets no minimum length. Very short spans give noisy vectors (INFERRED; skip spans under about 1 s, matching the offline diarizer's `minSegmentDurationSeconds`).
- Compute: the preprocessor runs `.cpuOnly` and the model `.cpuAndGPU`, because the ANE rejects the dynamic dimension.
- Storage: `~/Library/Application Support/FluidAudio/Models/campplus-coreml/` (`CamPlusPreprocessor.mlmodelc`, `CamPlusPlus.mlmodelc`). `.mlpackage` files are compiled on first load. `CampPlusModels.download()` takes no directory argument; for a custom path, place the files yourself and call `load(from:)`.
- The offline diarizer's `speakerDatabase` and segment `.embedding` are 256-d WeSpeaker vectors from a different model. Do not compare them with CAM++ vectors. Pick one source for voice matching across meetings and keep it.

## 5. WhisperKit

Dropped; see the Pin section.

## 6. Model storage summary

| Component | Default folder under `~/Library/Application Support/FluidAudio/Models/` | Custom dir |
|---|---|---|
| Batch TDT v3 | `parakeet-tdt-0.6b-v3-coreml` | `AsrModels.download(to:)`, `load(from:)` |
| Unified streaming | `parakeet-unified-en-0.6b-coreml` | `loadModels(to:)` (base dir), `loadModels(from:)` |
| Offline diarizer | `speaker-diarization-coreml` | `prepareModels(directory:)`, `OfflineDiarizerModels.load(from:)` |
| LS-EEND | `ls-eend-coreml/...` | `initialize(variant:..., cacheDirectory:)` |
| CAM++ | `campplus-coreml` | `load(from:)` only (download is fixed) |

## 7. Build check

A scratch package was set up with tools 6.2, `.macOS(.v26)` and Swift 5 language mode, depending on FluidAudio `exact: "0.17.7"`, on Apple Swift 6.4 / Xcode SDK 27. The package resolved (FluidAudio 0.17.7, no transitive packages), but `swift build` in the agent sandbox exited with no output and produced no binary. **Compilation of the snippets above is NOT verified.** The signatures were read from source; run the first `swift build` of the real package to confirm.
