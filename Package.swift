// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rMDP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RMDPMeasure", targets: ["RMDPMeasure"]),
        .library(name: "RMDPCodec", targets: ["RMDPCodec"]),
        .library(name: "RMDPRender", targets: ["RMDPRender"]),
        .library(name: "RMDPCapture", targets: ["RMDPCapture"]),
        .library(name: "RMDPSpeculate", targets: ["RMDPSpeculate"]),
        .library(name: "RMDPTiles", targets: ["RMDPTiles"]),
        .library(name: "RMDPCrisp", targets: ["RMDPCrisp"]),
        .library(name: "RMDPGeometry", targets: ["RMDPGeometry"]),
        .executable(name: "rmdp-latencybench", targets: ["rmdp-latencybench"]),
        .executable(name: "rmdp-pipeline", targets: ["rmdp-pipeline"]),
        .executable(name: "rmdp-capturetest", targets: ["rmdp-capturetest"]),
        .executable(name: "rmdp-scrollpoc", targets: ["rmdp-scrollpoc"]),
        .executable(name: "rmdp-classifybench", targets: ["rmdp-classifybench"]),
        .executable(name: "rmdp-crispbench", targets: ["rmdp-crispbench"]),
        .executable(name: "rmdp-cursorprobe", targets: ["rmdp-cursorprobe"]),
    ],
    targets: [
        // Pure measurement core — no framework deps, fully unit-testable.
        .target(name: "RMDPMeasure"),

        // Hardware codec wrappers (VideoToolbox).
        .target(name: "RMDPCodec", dependencies: ["RMDPMeasure"]),

        // Metal NV12→RGB renderer.
        .target(name: "RMDPRender", dependencies: ["RMDPMeasure"]),

        // ScreenCaptureKit capture.
        .target(name: "RMDPCapture", dependencies: ["RMDPMeasure"]),

        // Confidence-gated speculative scrolling (Mosh-derived).
        .target(name: "RMDPSpeculate", dependencies: ["RMDPMeasure"]),

        // CLASSIFY layer — tile ledger + video/crisp classifier (§2.1).
        .target(name: "RMDPTiles", dependencies: ["RMDPMeasure"]),

        // CRISP plane — lossless tile encodings (REF/PAL/RAW) + scroll (§2.3).
        .target(name: "RMDPCrisp", dependencies: ["RMDPMeasure"]),

        // Coordinate transform between capture pixels and screen points (§2.8 / cursor+input).
        .target(name: "RMDPGeometry"),

        // Codec-floor latency harness (synthetic frames, no TCC).
        .executableTarget(
            name: "rmdp-latencybench",
            dependencies: ["RMDPMeasure", "RMDPCodec"]
        ),

        // Encode→decode→Metal-render pipeline latency (synthetic frames, no TCC).
        .executableTarget(
            name: "rmdp-pipeline",
            dependencies: ["RMDPMeasure", "RMDPCodec", "RMDPRender"]
        ),

        // Real screen-capture latency probe (needs Screen Recording on a console session).
        .executableTarget(
            name: "rmdp-capturetest",
            dependencies: ["RMDPMeasure", "RMDPCapture"]
        ),

        // Speculative-scroll POC (headless, fully verifiable).
        .executableTarget(
            name: "rmdp-scrollpoc",
            dependencies: ["RMDPMeasure", "RMDPSpeculate"]
        ),

        // Tile-classifier cost benchmark (headless).
        .executableTarget(
            name: "rmdp-classifybench",
            dependencies: ["RMDPMeasure", "RMDPTiles"]
        ),

        // Crisp-plane bandwidth/throughput benchmark (headless).
        .executableTarget(
            name: "rmdp-crispbench",
            dependencies: ["RMDPMeasure", "RMDPCrisp", "RMDPTiles"]
        ),

        // Real cursor/display-geometry probe (needs a console session with a display).
        .executableTarget(
            name: "rmdp-cursorprobe",
            dependencies: ["RMDPGeometry"]
        ),

        .testTarget(name: "RMDPMeasureTests", dependencies: ["RMDPMeasure"]),
        .testTarget(name: "RMDPSpeculateTests", dependencies: ["RMDPSpeculate"]),
        .testTarget(name: "RMDPTilesTests", dependencies: ["RMDPTiles"]),
        .testTarget(name: "RMDPCrispTests", dependencies: ["RMDPCrisp"]),
        .testTarget(name: "RMDPGeometryTests", dependencies: ["RMDPGeometry"]),
    ],
    // Systems/C-interop code (VideoToolbox, CoreVideo). Swift 5 language mode keeps
    // strict-concurrency Sendable checks on non-Sendable CF types from drowning out
    // real signal; concurrency correctness here is enforced by design (serial queues),
    // not the type system.
    swiftLanguageModes: [.v5]
)
