// rmdp-host — the machine being controlled.
//
//   swift run -c release rmdp-host [--port 7443] [--password PW] [--fps 60]
//                                  [--bitrate-mbit 20] [--scale native|points]
//
// Pipeline (build-order step 3, the baseline everything later is argued against):
//   SCStream (NV12, BT.709) → H.264 low-latency (VideoToolbox) → QUIC datagrams
//   viewer input (QUIC stream) → CGEvent injection
//
// Needs Screen Recording (capture) and Accessibility (input) for the process that launches it
// (Terminal, when run from a shell). Capture runs only while a viewer is connected.

import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Synchronization
import RMDPMeasure
import RMDPCapture
import RMDPCodec
import RMDPProtocol
import RMDPTransport
import RMDPInput

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Options

struct Options {
    var port: UInt16 = 7443
    var password: String?
    var fps = 60
    var bitrateMbit = 20.0
    var native = true
    var viewOnly = false

    static func parse() -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--port": o.port = args.next().flatMap(UInt16.init) ?? o.port
            case "--password": o.password = args.next()
            case "--fps": o.fps = args.next().flatMap(Int.init) ?? o.fps
            case "--bitrate-mbit": o.bitrateMbit = args.next().flatMap(Double.init) ?? o.bitrateMbit
            case "--scale": o.native = (args.next() ?? "native") != "points"
            case "--view-only": o.viewOnly = true
            case "-h", "--help":
                print("usage: rmdp-host [--port 7443] [--password PW] [--fps 60] [--bitrate-mbit 20] [--scale native|points] [--view-only]")
                print("       --view-only ignores viewer input (safe for loopback testing on one machine)")
                print("       password may also come from $RMDP_PASSWORD; if neither is set a random one is generated")
                exit(0)
            default:
                print("unknown argument: \(a) (try --help)"); exit(64)
            }
        }
        o.password = o.password ?? ProcessInfo.processInfo.environment["RMDP_PASSWORD"]
        return o
    }
}

func randomPassword() -> String {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")   // no look-alikes
    return (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
}

// MARK: - Host pipeline

/// Owns capture → encode → send for one session, plus input injection.
///
/// Threading: SCK delivers on its own queue; every encoder call (new frame or keyframe re-encode)
/// is funnelled onto `encodeQueue` so the encoder sees one caller. Encoder output arrives on
/// VideoToolbox's (serial-per-session) callback thread. `needKeyframe` crosses threads, so it's
/// an atomic — no locks in the frame path.
final class HostPipeline: HostSessionDelegate, @unchecked Sendable {
    let opts: Options
    let streamW: Int, streamH: Int
    let displayBounds: CGRect

    private let encodeQueue = DispatchQueue(label: "rmdp.host.encode", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "rmdp.host.input", qos: .userInteractive)
    private var capture: ScreenCapture?
    private var encoder: H264Encoder?
    private var injector: InputInjector?
    private var session: HostSession?
    private var activity: NSObjectProtocol?

    private let needKeyframe = Atomic<Bool>(true)
    private var lastFrame: CVPixelBuffer?        // encodeQueue only
    private var lastPTS = CMTime.zero            // encodeQueue only
    private var nextFrameID: UInt32 = 0          // encoder callback only
    private var lastForcedIDRNanos: UInt64 = 0   // encodeQueue only

    /// Floor between forced IDRs. A drop under congestion must NOT trigger an IDR per frame —
    /// IDRs are 10–50× a P-frame, so that's positive feedback into the congestion (observed:
    /// 30 Mbit/s IDR storm into a dead link). Matches the viewer's keyframe re-request interval.
    static let minForcedIDRIntervalNanos: UInt64 = 250_000_000

    // Per-second counters (encoder callback thread; read by the stats printer racily — fine for logs).
    private let framesSent = Atomic<Int>(0)
    private let bytesSent = Atomic<Int>(0)
    private let keyframesSent = Atomic<Int>(0)
    private let encodeErrors = Atomic<Int>(0)

    /// Hardware H.264 low-latency encoder limits. Measured 2026-10-20 (M4 Pro): 4096-wide encodes,
    /// 5120×1440 creates a session then fails EVERY frame (callback -19354, no sample) — the
    /// ultrawide grey-screen bug. Larger displays are downscaled to fit (SCK scales for free; input
    /// mapping already handles any stream/display ratio via DisplayGeometry).
    static let maxEncodeWidth = 4096
    static let maxEncodeHeight = 2304

    /// The display's capture size, before clamping to encoder limits.
    let sourceW: Int, sourceH: Int

    init(opts: Options) {
        self.opts = opts
        let main = CGMainDisplayID()
        displayBounds = CGDisplayBounds(main)
        if opts.native, let mode = CGDisplayCopyDisplayMode(main) {
            sourceW = mode.pixelWidth; sourceH = mode.pixelHeight
        } else {
            sourceW = Int(displayBounds.width); sourceH = Int(displayBounds.height)
        }
        (streamW, streamH) = Self.fitToEncoder(width: sourceW, height: sourceH)
    }

    /// Scale (w, h) down — aspect preserved, even dimensions (4:2:0) — to the encoder's limits.
    static func fitToEncoder(width w: Int, height h: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maxEncodeWidth) / Double(w), Double(maxEncodeHeight) / Double(h))
        return (Int(Double(w) * scale) & ~1, Int(Double(h) * scale) & ~1)
    }

    /// Encode one blank frame at the stream size before accepting viewers. VideoToolbox can create
    /// a session it then can't encode with, and per-frame failures are otherwise silent.
    func selfTest() -> String? {
        do {
            let enc = try H264Encoder(width: streamW, height: streamH, bitrateBps: Int(opts.bitrateMbit * 1_000_000))
            let pb = try PixelBufferPool(width: streamW, height: streamH, minBuffers: 1).makeBuffer()
            var ok = false
            try enc.encode(pb, pts: CMTime(value: 1, timescale: 60), forceKeyframe: true) { ok = $0 != nil }
            enc.finish()
            return ok ? nil : "encoder produced no output at \(streamW)×\(streamH)"
        } catch {
            return "encoder setup failed at \(streamW)×\(streamH): \(error)"
        }
    }

    // MARK: HostSessionDelegate

    func welcome() -> ControlMessage.Welcome {
        .init(streamWidth: UInt32(streamW), streamHeight: UInt32(streamH),
              displayPointWidth: displayBounds.width, displayPointHeight: displayBounds.height)
    }

    func sessionStarted(_ s: HostSession) {
        print("▶ viewer '\(s.viewerName)' connected from \(s.remote)")
        session = s
        needKeyframe.store(true, ordering: .relaxed)
        // Remote user connected → keep the machine and display awake, and keep us out of App Nap.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
            reason: "rMDP viewer connected")
        inputQueue.async { [self] in
            injector = InputInjector(streamWidth: streamW, streamHeight: streamH, displayBounds: displayBounds)
        }
        encodeQueue.async { [self] in
            do {
                encoder = try H264Encoder(width: streamW, height: streamH,
                                          bitrateBps: Int(opts.bitrateMbit * 1_000_000))
            } catch {
                print("✗ encoder: \(error)"); return
            }
            startCapture()
        }
    }

    func sessionEnded(_ s: HostSession, error: Error?) {
        print("■ viewer '\(s.viewerName)' disconnected\(error.map { " (\($0))" } ?? "")")
        capture?.stop {}
        encodeQueue.async { [self] in
            capture = nil; encoder = nil; lastFrame = nil; lastForcedIDRNanos = 0
        }
        inputQueue.async { [self] in injector?.releaseAll(); injector = nil }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        session = nil
    }

    func session(_ s: HostSession, control m: ControlMessage) {
        switch m {
        case .keyframeRequest:
            needKeyframe.store(true, ordering: .relaxed)
            // On an idle desktop SCK sends no frames, so re-encode the last one as an IDR now.
            encodeQueue.async { [self] in
                if let pb = lastFrame { encode(pb, captureNanos: MonotonicClock.nowNanos()) }
            }
        case .stats(let st):
            let mbit = Double(st.bytesReceived) * 8 / Double(max(st.intervalMillis, 1)) / 1000
            print(String(format: "  viewer: %.1f Mbit/s  %d fps decoded  lost %d  rtt %.1f ms",
                         mbit, st.framesDecoded, st.framesLost, st.smoothedRTTMillis))
        default: break
        }
    }

    func session(_ s: HostSession, input m: ControlMessage) {
        if opts.viewOnly { return }
        inputQueue.async { [self] in
            guard let inj = injector else { return }
            switch m {
            case let .mouseMove(x, y, _): inj.mouseMove(x: x, y: y)
            case let .mouseButton(b, down, x, y, cc, _): inj.mouseButton(b, down: down, x: x, y: y, clickCount: cc)
            case let .scroll(dx, dy, _): inj.scroll(dx: dx, dy: dy)
            case let .key(code, down, flags, _): inj.key(code, down: down, flags: flags)
            default: break
            }
        }
    }

    // MARK: Pipeline

    private func startCapture() {
        let cap = ScreenCapture { [weak self] frame in
            // SCK callback — HOT PATH. Only `.complete` frames carry new pixels.
            guard let self, frame.status == .complete else { return }
            let pb = frame.pixelBuffer, ts = frame.displayTimeNanos
            encodeQueue.async { self.encode(pb, captureNanos: ts) }
        }
        capture = cap
        cap.start(fps: opts.fps, width: streamW, height: streamH) { err in
            if let err { print("✗ capture failed to start: \(err) — is Screen Recording granted?") }
        }
    }

    /// encodeQueue only.
    private func encode(_ pb: CVPixelBuffer, captureNanos: UInt64) {
        guard let encoder else { return }
        lastFrame = pb
        // PTS must strictly increase, including for keyframe re-encodes of the same buffer.
        var pts = CMTime(value: CMTimeValue(captureNanos), timescale: 1_000_000_000)
        if pts <= lastPTS { pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1_000_000_000)) }
        lastPTS = pts
        var force = false
        let now = MonotonicClock.nowNanos()
        if needKeyframe.load(ordering: .relaxed),
           now &- lastForcedIDRNanos >= Self.minForcedIDRIntervalNanos || lastForcedIDRNanos == 0 {
            force = needKeyframe.exchange(false, ordering: .relaxed)
            if force { lastForcedIDRNanos = now }
        }
        do {
            try encoder.encode(pb, pts: pts, forceKeyframe: force) { [weak self] sb in
                guard let self else { return }
                guard let sb, let au = H264AccessUnit(sampleBuffer: sb) else {
                    // Never silent: counted here, reported once a second off the frame path.
                    encodeErrors.add(1, ordering: .relaxed)
                    needKeyframe.store(true, ordering: .relaxed)
                    return
                }
                let frame = EncodedVideoFrame(frameID: nextFrameID, isKeyframe: au.isKeyframe,
                                              captureNanos: captureNanos,
                                              parameterSets: au.parameterSets, sampleData: au.avccData)
                nextFrameID &+= 1
                if session?.sendVideo(frame) == false {
                    // Send queue overflowed and dropped a frame: the viewer's chain is broken.
                    needKeyframe.store(true, ordering: .relaxed)
                }
                framesSent.add(1, ordering: .relaxed)
                bytesSent.add(au.avccData.count, ordering: .relaxed)
                if au.isKeyframe { keyframesSent.add(1, ordering: .relaxed) }
            }
        } catch {
            encodeErrors.add(1, ordering: .relaxed)
            needKeyframe.store(true, ordering: .relaxed)
        }
    }

    func printSendStats() {
        let f = framesSent.exchange(0, ordering: .relaxed)
        let b = bytesSent.exchange(0, ordering: .relaxed)
        let k = keyframesSent.exchange(0, ordering: .relaxed)
        let e = encodeErrors.exchange(0, ordering: .relaxed)
        guard session != nil else { return }
        print(String(format: "  host:   %.1f Mbit/s  %d fps encoded  %d IDR", Double(b) * 8 / 1e6, f, k)
              + (e > 0 ? "  ⚠ \(e) ENCODE ERRORS" : ""))
    }
}

// MARK: - Main

let opts = Options.parse()
let password = opts.password ?? randomPassword()

if !CGPreflightScreenCaptureAccess() {
    print("⚠ Screen Recording not granted — requesting. Grant it to the launching app (e.g. Terminal) and restart.")
    CGRequestScreenCaptureAccess()
}
if !opts.viewOnly && !InputInjector.isTrusted {
    print("⚠ Accessibility not granted — viewer input will be silently ignored. Requesting…")
    InputInjector.requestTrust()
}

let identity: HostIdentity
do { identity = try HostIdentity.loadOrCreate() } catch { print("✗ \(error)"); exit(1) }

let pipeline = HostPipeline(opts: opts)
print("rMDP host — protocol v\(RMDPWire.protocolVersion)")
print("  listening   udp/\(opts.port) (QUIC)")
print("  stream      \(pipeline.streamW)×\(pipeline.streamH) @ up to \(opts.fps) fps, \(opts.bitrateMbit) Mbit/s H.264"
      + (pipeline.streamW != pipeline.sourceW ? "  (display \(pipeline.sourceW)×\(pipeline.sourceH), downscaled to fit the H.264 encoder)" : ""))
if let problem = pipeline.selfTest() {
    print("✗ \(problem) — refusing to start (viewers would get a grey screen)")
    exit(1)
}
print("  identity    \(HostIdentity.shortFingerprint(identity.fingerprint))  (viewers pin this on first connect)")
if opts.viewOnly { print("  input       IGNORED (--view-only)") }
print("  password    \(opts.password == nil ? password + "  (generated — pass --password or $RMDP_PASSWORD to fix it)" : "(set)")")

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in pipeline.printSendStats() }

let server = HostServer(port: opts.port, password: password, identity: identity, delegate: pipeline)
Task {
    do { try await server.run() } catch { print("✗ listener: \(error)"); exit(1) }
}
RunLoop.main.run()
