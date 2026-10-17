import Foundation
import Security
import CryptoKit

/// Where rMDP keeps per-machine state: `~/Library/Application Support/rMDP/`.
public enum RMDPPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("rMDP", isDirectory: true)
    }

    static func ensureSupportDirectory() throws -> URL {
        let dir = supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }
}

public enum IdentityError: Error, CustomStringConvertible {
    case opensslFailed(String)
    case importFailed(OSStatus)
    case noIdentityInBundle

    public var description: String {
        switch self {
        case .opensslFailed(let s): return "generating host certificate with /usr/bin/openssl failed: \(s)"
        case .importFailed(let st): return "importing host identity failed (OSStatus \(st))"
        case .noIdentityInBundle: return "host identity bundle contained no identity"
        }
    }
}

/// The host's long-lived TLS identity: a self-signed RSA-2048 certificate, generated once and
/// reused so viewers can pin it (SSH-style trust on first use).
///
/// Stored as a PKCS#12 bundle + random passphrase, both 0600 in the support directory. Loaded
/// **in memory only** (`kSecImportToMemoryOnly`) — never touches the user's keychain.
/// RSA, not EC: the in-memory PKCS#12 import crashes on LibreSSL-generated EC keys (transport
/// spike 2026-10-17, memory/transport-api.md).
public struct HostIdentity {
    public let identity: sec_identity_t
    /// SHA-256 of the certificate DER, hex. This is what viewers pin and what the host prints so
    /// a human can verify it out of band.
    public let fingerprint: String

    public static func loadOrCreate() throws -> HostIdentity {
        let dir = try RMDPPaths.ensureSupportDirectory()
        let p12 = dir.appendingPathComponent("host-identity.p12")
        let pass = dir.appendingPathComponent("host-identity.pass")
        if !FileManager.default.fileExists(atPath: p12.path) || !FileManager.default.fileExists(atPath: pass.path) {
            try generate(p12: p12, passFile: pass)
        }
        let passphrase = try String(contentsOf: pass, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try load(p12: Data(contentsOf: p12), passphrase: passphrase)
    }

    static func load(p12: Data, passphrase: String) throws -> HostIdentity {
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: passphrase,
                                   kSecImportToMemoryOnly as String: true]
        let st = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)
        guard st == errSecSuccess else { throw IdentityError.importFailed(st) }
        guard let arr = items as? [[String: Any]], let raw = arr.first?[kSecImportItemIdentity as String] else {
            throw IdentityError.noIdentityInBundle
        }
        let secIdentity = raw as! SecIdentity
        var cert: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &cert)
        guard let cert, let identity = sec_identity_create(secIdentity) else { throw IdentityError.noIdentityInBundle }
        return HostIdentity(identity: identity, fingerprint: Self.fingerprint(of: cert))
    }

    public static func fingerprint(of cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Short human-comparable form: first 16 hex chars grouped in fours.
    public static func shortFingerprint(_ fp: String) -> String {
        stride(from: 0, to: min(16, fp.count), by: 4).map { i -> String in
            let s = fp.index(fp.startIndex, offsetBy: i)
            return String(fp[s..<fp.index(s, offsetBy: 4)])
        }.joined(separator: ":")
    }

    private static func generate(p12: URL, passFile: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rmdp-id-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        let key = tmp.appendingPathComponent("key.pem"), crt = tmp.appendingPathComponent("cert.pem")
        let host = ProcessInfo.processInfo.hostName
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                     "-keyout", key.path, "-out", crt.path, "-subj", "/CN=rmdp-host \(host)"])
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let passphrase = Data(bytes).base64EncodedString()
        // Passphrase goes via env, not argv, so it never shows up in `ps`.
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", crt.path, "-out", p12.path,
                     "-passout", "env:RMDP_P12_PASS"], env: ["RMDP_P12_PASS": passphrase])
        FileManager.default.createFile(atPath: passFile.path, contents: Data(passphrase.utf8),
                                       attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
    }

    private static func openssl(_ args: [String], env: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw IdentityError.opensslFailed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}

/// Viewer-side pin store (`known_hosts.json`): host:port → certificate fingerprint.
/// Policy = SSH's `accept-new`: first connection pins, a later mismatch is refused.
public struct KnownHosts {
    public enum Verdict: Equatable { case trusted, newlyPinned, mismatch(expected: String) }

    private let url: URL
    private var pins: [String: String]

    public init() throws {
        url = try RMDPPaths.ensureSupportDirectory().appendingPathComponent("known_hosts.json")
        pins = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    public static var path: String { RMDPPaths.supportDirectory.appendingPathComponent("known_hosts.json").path }

    public mutating func check(host: String, fingerprint: String) -> Verdict {
        if let pinned = pins[host] { return pinned == fingerprint ? .trusted : .mismatch(expected: pinned) }
        pins[host] = fingerprint
        if let d = try? JSONEncoder().encode(pins) {
            FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600])
        }
        return .newlyPinned
    }
}
