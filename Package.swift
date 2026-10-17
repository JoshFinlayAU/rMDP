// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "rMDP",
    // macOS 26: the NetworkConnection<QUIC> API (streams + datagrams on one connection) is
    // 26-only; the older NWConnectionGroup path could not do both. See memory/transport-api.md.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RMDPMeasure", targets: ["RMDPMeasure"]),
        .library(name: "RMDPCodec", targets: ["RMDPCodec"]),
        .library(name: "RMDPRender", targets: ["RMDPRender"]),
        .library(name: "RMDPCapture", targets: ["RMDPCapture"]),
        .library(name: "RMDPSpeculate", targets: ["RMDPSpeculate"]),
        .library(name: "RMDPTiles", targets: ["RMDPTiles"]),
        .library(name: "RMDPCrisp", targets: ["RMDPCrisp"]),
        .library(name: "RMDPGeometry", targets: ["RMDPGeometry"]),
        .library(name: "RMDPProtocol", targets: ["RMDPProtocol"]),
        .library(name: "RMDPTransport", targets: ["RMDPTransport"]),
        .library(name: "RMDPInput", targets: ["RMDPInput"]),
        .executable(name: "rmdp-latencybench", targets: ["rmdp-latencybench"]),
        .executable(name: "rmdp-pipeline", targets: ["rmdp-pipeline"]),
        .executable(name: "rmdp-capturetest", targets: ["rmdp-capturetest"]),
        .executable(name: "rmdp-scrollpoc", targets: ["rmdp-scrollpoc"]),
        .executable(name: "rmdp-classifybench", targets: ["rmdp-classifybench"]),
        .executable(name: "rmdp-crispbench", targets: ["rmdp-crispbench"]),
        .executable(name: "rmdp-cursorprobe", targets: ["rmdp-cursorprobe"]),
        .executable(name: "rmdp-host", targets: ["rmdp-host"]),
        .executable(name: "rmdp-viewer", targets: ["rmdp-viewer"]),
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

        // Wire format: control/input messages, video fragmentation, reassembly + loss policy.
        // Pure — no framework deps — so every framing path is unit-tested (§3).
        .target(name: "RMDPProtocol"),

        // QUIC transport (macOS 26 NetworkConnection): host listener, viewer client, TLS
        // identity + trust-on-first-use pinning, password auth.
        .target(name: "RMDPTransport", dependencies: ["RMDPProtocol"]),

        // Host-side CGEvent input injection through DisplayGeometry (§2.8).
        .target(name: "RMDPInput", dependencies: ["RMDPGeometry"]),

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

        // The two halves of the MVP remote desktop.
        .executableTarget(
            name: "rmdp-host",
            dependencies: ["RMDPMeasure", "RMDPCapture", "RMDPCodec", "RMDPProtocol", "RMDPTransport", "RMDPInput"]
        ),
        .executableTarget(
            name: "rmdp-viewer",
            dependencies: ["RMDPMeasure", "RMDPCodec", "RMDPRender", "RMDPProtocol", "RMDPTransport", "RMDPGeometry"]
        ),

        .testTarget(name: "RMDPMeasureTests", dependencies: ["RMDPMeasure"]),
        .testTarget(name: "RMDPSpeculateTests", dependencies: ["RMDPSpeculate"]),
        .testTarget(name: "RMDPTilesTests", dependencies: ["RMDPTiles"]),
        .testTarget(name: "RMDPCrispTests", dependencies: ["RMDPCrisp"]),
        .testTarget(name: "RMDPGeometryTests", dependencies: ["RMDPGeometry"]),
        .testTarget(name: "RMDPProtocolTests", dependencies: ["RMDPProtocol"]),
        .testTarget(name: "RMDPCodecTests", dependencies: ["RMDPCodec"]),
    ],
    // Systems/C-interop code (VideoToolbox, CoreVideo). Swift 5 language mode keeps
    // strict-concurrency Sendable checks on non-Sendable CF types from drowning out
    // real signal; concurrency correctness here is enforced by design (serial queues),
    // not the type system.
    swiftLanguageModes: [.v5]
)
