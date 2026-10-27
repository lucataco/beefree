// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BeeKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "BeeProtocol", targets: ["BeeProtocol"]),
        .library(name: "BeeKit", targets: ["BeeKit"]),
        .library(name: "BeePipeline", targets: ["BeePipeline"]),
    ],
    dependencies: [
        // Parakeet ASR, Silero VAD and pyannote diarization on Core ML. No traits: skips the bundled
        // text-normalization binary, which only TTS needs.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        // Framing, command ids, payload decoders, CBOR, SMP and the audio stream (decrypt + ADTS).
        // No Bluetooth code.
        .target(name: "BeeProtocol"),
        // CoreBluetooth central, transport, the serialized request client and the audio recorder.
        .target(name: "BeeKit", dependencies: ["BeeProtocol"]),
        // Everything after capture: decode, VAD, transcription, speakers, conversations, notes.
        .target(name: "BeePipeline", dependencies: [
            "BeeProtocol",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .testTarget(name: "BeeProtocolTests", dependencies: ["BeeProtocol"]),
        .testTarget(name: "BeeKitTests", dependencies: ["BeeKit"]),
        .testTarget(name: "BeePipelineTests", dependencies: ["BeePipeline"]),
    ]
)
