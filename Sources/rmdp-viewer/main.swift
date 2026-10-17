// rmdp-viewer — the machine you sit at.
//
//   swift run -c release rmdp-viewer <host>[:port] [--password PW]
//
// QUIC datagrams → reassembly/loss policy → H.264 decode (VideoToolbox) → Metal (CAMetalLayer).
// Local keyboard/mouse/trackpad → input stream. The cursor is your LOCAL cursor (never in the
// stream) — zero perceived pointer latency, per §2.8.
//
// The window title is the live telemetry: fps, bitrate, end-to-end latency (host scanout →
// viewer GPU done, clock-offset-corrected via ping), RTT, frames lost.

import AppKit
import QuartzCore
import CoreMedia
import RMDPMeasure
import RMDPCodec
import RMDPRender
import RMDPProtocol
import RMDPTransport
import RMDPGeometry

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Options

struct Options {
    var host = ""
    var port: UInt16 = 7443
    var password: String?

    static func parse() -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--password": o.password = args.next()
            case "-h", "--help":
                print("usage: rmdp-viewer <host>[:port] [--password PW]   (or $RMDP_PASSWORD, or prompt)")
                exit(0)
            default:
                if a.hasPrefix("-") { print("unknown argument: \(a)"); exit(64) }
                let parts = a.split(separator: ":", maxSplits: 1)
                o.host = String(parts[0])
                if parts.count == 2 { o.port = UInt16(parts[1]) ?? o.port }
            }
        }
        if o.host.isEmpty { print("usage: rmdp-viewer <host>[:port] [--password PW]"); exit(64) }
        o.password = o.password ?? ProcessInfo.processInfo.environment["RMDP_PASSWORD"]
        return o
    }
}

// MARK: - Telemetry

/// Clock sync + RTT from ping/pong. Offset = host clock − viewer clock, taken from the
/// lowest-RTT sample in a sliding window (least queueing → least asymmetry error).
final class LinkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(rtt: UInt64, offset: Int64)] = []
    private(set) var smoothedRTTMillis: Double = 0
    static let window = 20
    static let rttAlpha = 0.125

    func pong(viewerNanos t0: UInt64, hostNanos th: UInt64) {
        let t1 = MonotonicClock.nowNanos()
        let rtt = t1 &- t0
        let offset = Int64(bitPattern: th) - Int64(bitPattern: t0 / 2 + t1 / 2)
        lock.lock(); defer { lock.unlock() }
        samples.append((rtt, offset))
        if samples.count > Self.window { samples.removeFirst() }
        let ms = Double(rtt) / 1e6
        smoothedRTTMillis = smoothedRTTMillis == 0 ? ms : smoothedRTTMillis + Self.rttAlpha * (ms - smoothedRTTMillis)
    }

    /// Host monotonic ns → viewer monotonic ns. nil until the first pong.
    func toViewer(hostNanos: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard let best = samples.min(by: { $0.rtt < $1.rtt }) else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: hostNanos) - best.offset)
    }
}

final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    var bytes = 0, decoded = 0, presented = 0, lost = 0
    let latency = LatencyRecorder(capacity: 4096)
    func with<T>(_ body: (Counters) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
}

// MARK: - Session

/// Owns the network → decode → render path. `rxQueue` owns the reassembler.
final class ViewerSession: @unchecked Sendable {
    let client: ViewerClient
    let welcome: ControlMessage.Welcome
    let clock = LinkClock()
    let counters = Counters()
    var renderer: LayerRenderer?

    private let rxQueue = DispatchQueue(label: "rmdp.viewer.rx", qos: .userInteractive)
    private var reassembler = Reassembler()          // rxQueue only
    private var format: CMVideoFormatDescription?    // rxQueue only
    private let decoder = H264Decoder()
    private var pollTimer: DispatchSourceTimer?
    /// How often the reassembler's time-based rules run when no datagrams arrive.
    static let pollIntervalMillis = 10

    init(client: ViewerClient, welcome: ControlMessage.Welcome) {
        self.client = client
        self.welcome = welcome
    }

    func start(onClosed: @escaping @Sendable (Error?) -> Void) {
        let t = DispatchSource.makeTimerSource(queue: rxQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Self.pollIntervalMillis))
        t.setEventHandler { [self] in handle(reassembler.poll(nowNanos: MonotonicClock.nowNanos())) }
        t.resume()
        pollTimer = t

        Task.detached(priority: .high) { [self] in
            do {
                try await client.receiveDatagrams { d in
                    self.rxQueue.async {
                        self.counters.with { $0.bytes += d.count }
                        self.handle(self.reassembler.ingest(d, nowNanos: MonotonicClock.nowNanos()))
                    }
                }
            } catch { onClosed(error) }
        }
        Task.detached { [self] in
            do {
                try await client.receiveControl { m in
                    if case let .pong(v, h) = m { self.clock.pong(viewerNanos: v, hostNanos: h) }
                }
            } catch { onClosed(error) }
        }
        // Keepalive + clock sync.
        Task.detached { [self] in
            while true {
                try? await client.sendControl(.ping(viewerNanos: MonotonicClock.nowNanos()))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// rxQueue only.
    private func handle(_ events: [Reassembler.Event]) {
        for e in events {
            switch e {
            case .requestKeyframe:
                Task { try? await client.sendControl(.keyframeRequest) }
            case .frame(let f):
                decode(f)
            }
        }
        let lost = reassembler.framesLost
        counters.with { $0.lost = lost }
    }

    private func decode(_ f: EncodedVideoFrame) {
        if f.isKeyframe { format = H264AccessUnit.formatDescription(parameterSets: f.parameterSets) ?? format }
        guard let format else { return }
        let au = H264AccessUnit(isKeyframe: f.isKeyframe, parameterSets: f.parameterSets, avccData: f.sampleData)
        guard let sb = au.sampleBuffer(format: format) else { return }
        let captureNanos = f.captureNanos
        do {
            try decoder.decode(sb) { [self] img in
                guard let img else { return }
                counters.with { $0.decoded += 1 }
                renderer?.draw(img) { [self] presented in
                    guard presented else { return }
                    let now = MonotonicClock.nowNanos()
                    counters.with { c in
                        c.presented += 1
                        if let cap = clock.toViewer(hostNanos: captureNanos) {
                            c.latency.record(Double(Int64(bitPattern: now &- cap)) / 1e6)
                        }
                    }
                }
            }
        } catch {
            // A decode error means the chain is suspect — recover via IDR.
            Task { try? await client.sendControl(.keyframeRequest) }
        }
    }

    /// Called once a second: report to host, return a title string.
    func tick() -> String {
        let (bytes, decoded, presented, lost, lat) = counters.with { c -> (Int, Int, Int, Int, LatencySummary) in
            defer { c.bytes = 0; c.decoded = 0; c.presented = 0 }
            let s = c.latency.summarize()
            c.latency.reset()
            return (c.bytes, c.decoded, c.presented, c.lost, s)
        }
        let rtt = clock.smoothedRTTMillis
        Task {
            try? await client.sendControl(.stats(.init(intervalMillis: 1000, bytesReceived: UInt32(bytes),
                                                       framesDecoded: UInt32(decoded), framesLost: UInt32(lost),
                                                       smoothedRTTMillis: Float(rtt))))
        }
        let latText = lat.count > 0 ? String(format: "e2e p50 %.0f / p95 %.0f ms", lat.p50, lat.p95) : "e2e –"
        return String(format: "rMDP — %@ · %d fps · %.1f Mbit/s · %@ · RTT %.1f ms · lost %d",
                      client.hostKey, presented, Double(bytes) * 8 / 1e6, latText, rtt, lost)
    }
}

// MARK: - Video view (Metal surface + input capture)

final class StreamView: NSView {
    let metalLayer = CAMetalLayer()
    var session: ViewerSession!
    private var tracking: NSTrackingArea?
    private var geometry: DisplayGeometry {
        DisplayGeometry(capturePixelW: Int(session.welcome.streamWidth), capturePixelH: Int(session.welcome.streamHeight),
                        contentPointW: max(bounds.width, 1), contentPointH: max(bounds.height, 1))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    override func viewDidChangeBackingProperties() { needsLayout = true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    // MARK: Input → capture pixels

    private func pixel(_ e: NSEvent) -> (Float, Float) {
        // NSView is not flipped → bottom-left origin → the "flipped" helper.
        let p = convert(e.locationInWindow, from: nil)
        let px = geometry.pointFlippedToPixel(x: p.x, y: p.y)
        return (Float(px.x), Float(px.y))
    }
    private var now: UInt64 { MonotonicClock.nowNanos() }

    private func move(_ e: NSEvent) { let (x, y) = pixel(e); session.client.sendInput(.mouseMove(x: x, y: y, viewerNanos: now)) }
    private func button(_ e: NSEvent, down: Bool) {
        let (x, y) = pixel(e)
        session.client.sendInput(.mouseButton(button: UInt8(clamping: e.buttonNumber), down: down, x: x, y: y,
                                              clickCount: UInt8(clamping: e.clickCount), viewerNanos: now))
    }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func mouseDown(with e: NSEvent) { button(e, down: true) }
    override func mouseUp(with e: NSEvent) { button(e, down: false) }
    override func rightMouseDown(with e: NSEvent) { button(e, down: true) }
    override func rightMouseUp(with e: NSEvent) { button(e, down: false) }
    override func otherMouseDown(with e: NSEvent) { button(e, down: true) }
    override func otherMouseUp(with e: NSEvent) { button(e, down: false) }

    /// Line-based wheels (non-precise) report lines; convert to points so the host gets one unit.
    static let pointsPerScrollLine: CGFloat = 10

    override func scrollWheel(with e: NSEvent) {
        let k = e.hasPreciseScrollingDeltas ? 1 : Self.pointsPerScrollLine
        session.client.sendInput(.scroll(dx: Float(e.scrollingDeltaX * k), dy: Float(e.scrollingDeltaY * k), viewerNanos: now))
    }

    override func keyDown(with e: NSEvent) { key(e, down: true) }
    override func keyUp(with e: NSEvent) { key(e, down: false) }
    /// Cmd-combos arrive here first; forward them to the host instead of the local menu.
    /// (Close the window with the title-bar button to quit the viewer.)
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        if e.type == .keyDown { key(e, down: true) } else if e.type == .keyUp { key(e, down: false) }
        return true
    }
    override func flagsChanged(with e: NSEvent) {
        let flag: NSEvent.ModifierFlags? = switch e.keyCode {
        case 0x37, 0x36: .command
        case 0x38, 0x3C: .shift
        case 0x3A, 0x3D: .option
        case 0x3B, 0x3E: .control
        case 0x39: .capsLock
        case 0x3F: .function
        default: nil
        }
        guard let flag else { return }
        key(e, down: e.modifierFlags.contains(flag))
    }
    private func key(_ e: NSEvent, down: Bool) {
        session.client.sendInput(.key(keyCode: e.keyCode, down: down,
                                      flags: UInt64(e.modifierFlags.rawValue), viewerNanos: now))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let opts: Options
    var window: NSWindow?
    var session: ViewerSession?

    init(opts: Options) { self.opts = opts }

    func applicationDidFinishLaunching(_ n: Notification) {
        let password = opts.password ?? {
            guard let p = getpass("password for \(opts.host): ") else { exit(1) }
            return String(cString: p)
        }()
        let client = ViewerClient(host: opts.host, port: opts.port)
        client.onNewHostPinned = { fp in
            print("🔐 first connection to \(client.hostKey) — pinned host identity \(HostIdentity.shortFingerprint(fp))")
            print("   (compare with the 'identity' line the host printed)")
        }
        print("connecting to \(client.hostKey)…")
        Task { @MainActor in
            do {
                let w = try await client.connect(password: password, viewerName: Host.current().localizedName ?? "viewer")
                print("✓ connected — stream \(w.streamWidth)×\(w.streamHeight)")
                open(client: client, welcome: w)
            } catch {
                print("✗ \(error)")
                exit(1)
            }
        }
    }

    @MainActor
    private func open(client: ViewerClient, welcome w: ControlMessage.Welcome) {
        let s = ViewerSession(client: client, welcome: w)
        session = s

        // Fit the stream into ~85% of the screen, preserving aspect so coordinates stay exact.
        let aspect = CGFloat(w.streamWidth) / CGFloat(w.streamHeight)
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var size = NSSize(width: vf.width * 0.85, height: vf.width * 0.85 / aspect)
        if size.height > vf.height * 0.85 { size = NSSize(width: vf.height * 0.85 * aspect, height: vf.height * 0.85) }

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.contentAspectRatio = NSSize(width: CGFloat(w.streamWidth), height: CGFloat(w.streamHeight))
        win.title = "rMDP — \(client.hostKey)"
        win.delegate = self
        let view = StreamView(frame: NSRect(origin: .zero, size: size))
        view.session = s
        win.contentView = view
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        window = win
        NSApp.activate()

        do { s.renderer = try LayerRenderer(layer: view.metalLayer) } catch { print("✗ renderer: \(error)"); exit(1) }
        s.start { err in
            print("■ disconnected\(err.map { ": \($0)" } ?? "")")
            exit(0)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.session else { return }
                let title = s.tick()
                self.window?.title = title
                print(title)
            }
        }
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}

let opts = Options.parse()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(opts: opts)
app.delegate = delegate
app.run()
